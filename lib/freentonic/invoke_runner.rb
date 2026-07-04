# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "securerandom"

module Freentonic
  # Per-invoke work unit. Owns the filesystem side of running one freentonic
  # subprocess: creating the run directory, spawning the child with a scoped
  # ENV, enforcing the timeout. Inline credentials are passed in-process via
  # an inherited pipe (fd 3) consumed by the child's `inline_fd` secret
  # backend — no on-disk artifact. Never touches the host-owned run directory
  # or the chrome profile directory (both are meant to persist).
  #
  # Serialization is the server's responsibility — this class assumes the
  # caller only runs one InvokeRunner#run at a time.
  class InvokeRunner
    Result = Struct.new(
      :run_id, :exit_code, :error_kind, :duration_ms, :artifacts,
      :log_path, :warnings, :chrome_profile_dir,
      keyword_init: true
    )

    # Maps (exit_code, timed_out, signaled) to a coarse error_kind the web
    # app can branch on for retry / UX without grepping the log:
    #   nil          — success (exit_code == 0)
    #   "timeout"    — the watchdog killed the child after timeout_sec
    #   "signal"     — child died on a signal (SIGSEGV, SIGBUS, external kill...)
    #   "user_error" — UserError (CLI exits 1 for bad YAML, missing secrets, etc.)
    #   "export_error" — ExportError (CLI exits 2 for receiver rejection, etc.)
    #   "unknown"    — any other non-zero exit code
    ERROR_KINDS = %w[user_error export_error timeout signal unknown].freeze

    def self.classify_error(exit_code, timed_out, signaled)
      return nil if exit_code.to_i.zero?
      return "timeout" if timed_out
      return "signal"  if signaled
      case exit_code
      when 1 then "user_error"
      when 2 then "export_error"
      else        "unknown"
      end
    end

    Artifact = Struct.new(:path, :size, keyword_init: true) do
      def to_h
        { "path" => path, "size" => size }
      end
    end

    DEFAULT_RUNS_DIR             = "/workspace/runs"
    DEFAULT_WORKFLOWS_DIR        = "/home/freentonic/workflows"
    DEFAULT_CHROME_PROFILE_ROOT  = File.expand_path("~/.cache/freentonic/chrome")
    DEFAULT_FREENTONIC_CMD       = [RbConfig.ruby, "-I/opt/freentonic/lib", "/opt/freentonic/bin/freentonic"].freeze
    DEFAULT_ARTIFACT_ROOT        = "/workspace"
    DEFAULT_VNC_PASSWORD_FILE    = "/dev/shm/freentonic/vnc-password"

    SIGTERM_GRACE_SECONDS = 10

    # 32 bytes of hex = 128 bits. Way past VNC's 8-char-truncation entropy
    # ceiling, which is the point — we want an unreachable sentinel.
    def self.random_unreachable_password
      SecureRandom.hex(32)
    end

    attr_reader :workflows_dir, :runs_dir, :chrome_profile_root, :vnc_password_file

    # Pre-assigned fd number used to hand inline credentials to the child.
    # 0/1/2 are stdin/stdout/stderr; 3 is the first free slot.
    INLINE_SECRETS_FD = 3

    def initialize(
      workflows_dir:          DEFAULT_WORKFLOWS_DIR,
      runs_dir:               DEFAULT_RUNS_DIR,
      chrome_profile_root:    DEFAULT_CHROME_PROFILE_ROOT,
      freentonic_cmd:         DEFAULT_FREENTONIC_CMD,
      artifact_root:          DEFAULT_ARTIFACT_ROOT,
      vnc_password_file:      DEFAULT_VNC_PASSWORD_FILE,
      logger:                 nil
    )
      @workflows_dir       = workflows_dir
      @runs_dir            = runs_dir
      @chrome_profile_root = chrome_profile_root
      @freentonic_cmd      = Array(freentonic_cmd).dup.freeze
      @artifact_root       = artifact_root
      @vnc_password_file   = vnc_password_file
      @logger              = logger
    end

    # Run one validated InvokeRequest.
    #
    # @param request [InvokeRequest]
    # @yieldparam pid [Integer], pgid [Integer] yielded once, right after
    #   Process.spawn returns, so the caller can register the child for
    #   external cancel support.
    # @return [Result]
    def run(request, &on_start)
      run_dir = File.join(@runs_dir, request.run_id)
      ensure_contained!(run_dir, @runs_dir, "run_id")
      FileUtils.mkdir_p(run_dir, mode: 0o750)
      # Rendezvous directory for out-of-band prompts (2FA / SMS code entry).
      # Pre-created so the server's GET /runs/{run_id}/prompts can return an
      # empty list immediately without racing the subprocess startup.
      FileUtils.mkdir_p(File.join(run_dir, "prompts"), mode: 0o700)

      chrome_profile_dir = File.join(@chrome_profile_root, request.profile_key)
      ensure_contained!(chrome_profile_dir, @chrome_profile_root, "profile_key")
      FileUtils.mkdir_p(chrome_profile_dir, mode: 0o750)

      started_at = Time.now
      warnings   = []

      secrets_arg, extra_fds = build_secrets_handoff(request)

      env  = build_env(request, chrome_profile_dir: chrome_profile_dir, run_dir: run_dir)
      argv = build_argv(request, secrets_arg: secrets_arg, run_dir: run_dir)

      # Set the VNC password for this run before spawning the child. If the
      # caller didn't supply one, we write an unreachable value so attaching
      # noVNC is impossible for this invoke. The paired ensure-block write
      # (see below) relocks VNC as soon as the run finishes.
      write_vnc_password(request.vnc_password || self.class.random_unreachable_password)

      log_path = File.join(run_dir, "log")
      exit_code, timed_out, signaled = spawn_and_wait(env, argv, log_path, request.timeout_sec, extra_fds: extra_fds, &on_start)
      warnings << "timeout reached (#{request.timeout_sec}s); child was terminated" if timed_out

      Result.new(
        run_id:             request.run_id,
        exit_code:          exit_code,
        error_kind:         self.class.classify_error(exit_code, timed_out, signaled),
        duration_ms:        ((Time.now - started_at) * 1000).to_i,
        artifacts:          collect_artifacts(run_dir),
        log_path:           relative_artifact_path(log_path),
        warnings:           warnings,
        chrome_profile_dir: chrome_profile_dir
      )
    ensure
      cleanup_chrome(chrome_profile_dir) if chrome_profile_dir
      # Always relock VNC after a run, regardless of exit path (timeout,
      # crash, validation-late error). x11vnc re-reads its passwdfile
      # on every new client connection, so the next noVNC attach sees
      # this unreachable sentinel.
      write_vnc_password(self.class.random_unreachable_password)
    end

    private

    # Overwrite the x11vnc passwdfile. The file is picked up on every
    # new VNC client connection (x11vnc's `-passwdfile read:` re-reads
    # the file per connection — the prefix name is misleading, see
    # docker-entrypoint.sh). Updating it here takes effect without any
    # signal or x11vnc restart.
    #
    # Failures are non-fatal: the most common is "path doesn't exist"
    # (running outside the container, or the entrypoint hasn't set up the
    # tmpfs yet). We warn and move on rather than killing a sync because
    # the VNC debug channel isn't writable.
    def write_vnc_password(value)
      return if @vnc_password_file.nil? || @vnc_password_file.empty?
      parent = File.dirname(@vnc_password_file)
      return unless Dir.exist?(parent)
      File.open(@vnc_password_file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(value)
      end
    rescue Errno::EACCES, Errno::ENOENT, Errno::EROFS, Errno::ENOSPC => e
      log("vnc passwdfile write failed at #{@vnc_password_file}: #{e.class}: #{e.message}")
    end

    # Returns [secrets_arg, extra_fds] where:
    #   secrets_arg : [:fd, n] or [:file, path] — consumed by #build_argv.
    #   extra_fds   : Hash<Integer, IO> merged into Process.spawn options
    #                 (the IOs are closed in the parent after spawn returns,
    #                 in #spawn_and_wait).
    #
    # For inline credentials we buffer the dotenv payload through a pipe
    # whose read end the child inherits as INLINE_SECRETS_FD. The payload
    # is written and the write end closed BEFORE spawn so the child sees
    # EOF after consuming the buffered bytes. Inline payloads are well
    # below the Linux 64KB pipe buffer, so the synchronous write never
    # blocks; no writer thread required.
    def build_secrets_handoff(request)
      if request.credentials_inline
        read_io, write_io = IO.pipe
        payload = request.credentials_inline
          .sort.map { |k, v| "#{k}=#{v}" }.join("\n")
        write_io.write(payload)
        write_io.close
        [[:fd, INLINE_SECRETS_FD], { INLINE_SECRETS_FD => read_io }]
      else
        [[:file, request.credentials_file], {}]
      end
    end

    def build_env(request, chrome_profile_dir:, run_dir:)
      env = {
        "PATH"                           => ENV["PATH"] || "/usr/local/bin:/usr/bin:/bin",
        "HOME"                           => ENV["HOME"] || "/home/freentonic",
        "LANG"                           => ENV["LANG"] || "en_US.UTF-8",
        "DISPLAY"                        => ENV["DISPLAY"] || ":99",
        "FREENTONIC_RUN_ID"              => request.run_id,
        "FREENTONIC_RUN_DIR"             => run_dir,
        "FREENTONIC_CHROME_PROFILE_DIR"  => chrome_profile_dir
      }
      if request.export && request.export["mode"] == "http" && request.export["token"]
        env["FREENTONIC_HTTP_TOKEN"] = request.export["token"]
      end
      env
    end

    def build_argv(request, secrets_arg:, run_dir:)
      argv = @freentonic_cmd.dup
      argv << "--no-sandbox"
      argv.push("--workflow", request.workflow_path)
      case secrets_arg
      in [:file, path] then argv.push("--secrets", "plain_file", "--secrets-file", path)
      in [:fd,   n]    then argv.push("--secrets", "inline_fd",  "--secrets-fd",   n.to_s)
      end
      argv.push("--lookback", request.lookback.to_s) if request.lookback
      argv << "--isolated" if request.chrome["isolated"]
      argv << "--headless" if request.chrome["headless"]
      argv << "--interactive" if request.interactive
      argv << "--recording"   if request.recording

      # Skip exporter argv plumbing in interactive (browse) and
      # recording modes — both short-circuit the engine at Connect, so
      # no exporter ever fires. Pushing --export with no scrape output
      # would fail CLI validation downstream.
      if (export = request.export) && !request.interactive && !request.recording
        argv.push("--export", export["mode"])
        case export["mode"]
        when "http"
          argv.push("--export-url", export["url"])
          argv.push("--export-method", export["method"]) if export["method"]
          argv.push("--export-content-type", export["content_type"]) if export["content_type"]
          Array(export["headers"]).each do |name, value|
            argv.push("--export-header", "#{name}=#{value}")
          end
          # NOTE: --export-token intentionally omitted. The HTTP exporter at
          # lib/freentonic/exporters/http.rb falls back to
          # ENV["FREENTONIC_HTTP_TOKEN"], which build_env sets. Keeping the
          # token off argv avoids /proc/<pid>/cmdline exposure.
        else
          argv.push("--export-path", File.join(run_dir, export["path"]))
        end
      end

      argv
    end

    def spawn_and_wait(env, argv, log_path, timeout_sec, extra_fds: {}, &on_start)
      log_fd = File.open(log_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600)
      begin
        pid = Process.spawn(
          env, *argv,
          unsetenv_others: true,
          close_others:    true,
          pgroup:          true,
          out:             log_fd,
          err:             log_fd,
          **extra_fds
        )
      ensure
        log_fd.close rescue nil
        # Parent's copies of any inherited pipe ends are no longer needed —
        # the child has its own dup'd fd. Closing here releases the
        # parent-side fd promptly instead of waiting for GC.
        extra_fds.each_value { |io| io.close rescue nil }
      end

      pgid = begin
        Process.getpgid(pid)
      rescue Errno::ESRCH
        pid
      end

      on_start&.call(pid, pgid)

      deadline = Time.now + timeout_sec
      timed_out = false
      status = nil

      loop do
        result = Process.wait2(pid, Process::WNOHANG)
        if result
          _, status = result
          break
        end

        if Time.now >= deadline && !timed_out
          timed_out = true
          send_signal_to_group(pgid, "TERM")
          grace_deadline = Time.now + SIGTERM_GRACE_SECONDS
          while Time.now < grace_deadline
            result = Process.wait2(pid, Process::WNOHANG)
            if result
              _, status = result
              break
            end
            sleep 0.2
          end
          unless status
            send_signal_to_group(pgid, "KILL")
            _, status = Process.wait2(pid)
          end
          break
        end

        sleep 0.2
      end

      exit_code = if status.exited?
        status.exitstatus
      elsif status.signaled?
        128 + status.termsig
      else
        -1
      end

      [exit_code, timed_out, status.signaled?]
    end

    def send_signal_to_group(pgid, signal)
      Process.kill("-#{signal}", pgid)
    rescue Errno::ESRCH
      nil
    end

    def cleanup_chrome(profile_dir)
      return unless ChromeCdp.respond_to?(:kill_chrome_for)
      ChromeCdp.kill_chrome_for(profile_dir)
    rescue StandardError => e
      log("chrome cleanup failed for #{profile_dir}: #{e.class}: #{e.message}")
    end

    # Defense in depth behind InvokeRequest's RUN_ID/PROFILE_KEY patterns:
    # verify the composed path resolves strictly *under* its root before we
    # mkdir into it. Catches any future pattern regression that would let a
    # `.`/`..` segment escape (e.g. run_id=".." truncating the workspace or
    # globbing every tenant's runs into the response).
    def ensure_contained!(path, root, label)
      expanded = File.expand_path(path)
      root_expanded = File.expand_path(root)
      unless expanded.start_with?(root_expanded + File::SEPARATOR)
        raise InvokeError.new(:bad_request, "#{label} escapes its containment root")
      end
    end

    def collect_artifacts(run_dir)
      return [] unless Dir.exist?(run_dir)
      entries = Dir.glob(File.join(run_dir, "**", "*"), File::FNM_DOTMATCH).reject do |p|
        File.basename(p) == "." || File.basename(p) == ".." || File.directory?(p)
      end
      entries.sort.map do |p|
        Artifact.new(path: relative_artifact_path(p), size: File.size(p))
      end
    end

    def relative_artifact_path(absolute)
      root = @artifact_root.chomp(File::SEPARATOR) + File::SEPARATOR
      absolute.start_with?(root) ? absolute[root.length..] : absolute
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
