# frozen_string_literal: true

require "optparse"
require "open3"

module Freentonic
  # Command-line entry point. Drives the Engine from argv.
  #
  # Usage examples:
  #
  #   freentonic --workflow providers/acme/workflow.yml \
  #     --export json --export-path out.json
  #
  #   freentonic --workflow providers/acme/workflow.yml \
  #     --through extract --dump-raw /tmp/raw.json
  #
  #   freentonic --workflow providers/acme/workflow.yml \
  #     --from-raw /tmp/raw.json \
  #     --export http --export-url https://api.example.com/push --export-token $TOK
  class Cli
    STAGE_NAMES = %w[connect elevate extract normalize export].freeze

    def initialize(stdout: $stdout, stderr: $stderr, stdin: $stdin)
      @stdout = stdout
      @stderr = stderr
      @stdin = stdin
    end

    def run(argv)
      argv = pre_process_requires(argv.dup)
      options = parse(argv)
      return run_init(options) if options[:init] # before validate!; CREATES the workflow
      return run_schema_json(options) if options[:schema_json] # before validate!; needs no --workflow
      return run_compile_recording(options) if options[:compile_recording] # before validate!; needs no --workflow
      validate!(options)
      return run_lint(options) if options[:lint]
      execute(options)
      0
    rescue UserError => error
      @stderr.puts(error.message)
      1
    rescue ExportError => error
      @stderr.puts(error.message)
      2
    end

    private

    # `-r path/to/file.rb` loads user code BEFORE option parsing so custom
    # exporters / normalizers / secret backends have a chance to call
    # Freentonic::Exporters.register and friends at load time.
    def pre_process_requires(argv)
      remaining = []
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "-r" || arg == "--require"
          path = argv[i + 1] or raise UserError, "-r requires a path argument"
          require File.expand_path(path)
          i += 2
        elsif arg.start_with?("-r")
          require File.expand_path(arg[2..])
          i += 1
        else
          remaining << arg
          i += 1
        end
      end
      remaining
    end

    def parse(argv)
      options = {
        workflow: nil,
        lookback_days: nil,
        isolated: false,
        reset_profile: false,
        headless: false,
        # Env default so a container can make sandbox-less launch the shell-wide
        # baseline (the author container exports it: with --cap-drop ALL the
        # Chrome sandbox can't start, and a bare `freentonic --recording` typed
        # in the iterate shell would otherwise hang silently on the debug port).
        # The --no-sandbox flag still works and an explicit flag always wins.
        no_sandbox: ENV["FREENTONIC_NO_SANDBOX"] == "1",
        cdp_port: nil,
        only_stage: nil,
        through_stage: nil,
        dump_raw: nil,
        from_raw: nil,
        dump_normalized: nil,
        from_normalized: nil,
        secrets_backend: nil,
        secrets_file: nil,
        secrets_fd: nil,
        exporters: [], # array of { name:, options: {} }
        purge: false,
        force: false,
        interactive: false,
        recording: false,
        step: false,
        lint: false,
        schema_json: false,
        compile_recording: nil,
        init: false,
        url: nil,
        init_secrets: [],
        ready_url: nil,
        out: nil
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: freentonic --workflow PATH [options]"

        opts.on("--workflow PATH", "Path to workflow YAML") { |v| options[:workflow] = v }
        opts.on("--lookback DAYS", Integer, "Days of history to fetch") { |v| options[:lookback_days] = v }
        opts.on("--isolated", "Use a temporary Chrome profile (fresh login)") { options[:isolated] = true }
        opts.on("--reset-profile", "Wipe the persistent Chrome profile before launch (clean slate; keeps persisting after). Handy for --recording a bank's full-entry login when the remembered profile skips it.") { options[:reset_profile] = true }
        opts.on("--headless", "Run Chrome in headless mode (no visible window)") { options[:headless] = true }
        opts.on("--no-sandbox", "Disable Chrome sandbox (required in Docker)") { options[:no_sandbox] = true }
        opts.on("--port PORT", Integer, "Chrome debug port (default 9222)") { |v| options[:cdp_port] = v }

        opts.on("--only-stage STAGE", STAGE_NAMES, "Run exactly one stage (#{STAGE_NAMES.join("|")})") { |v| options[:only_stage] = v.to_sym }
        opts.on("--through STAGE", STAGE_NAMES, "Run stages up to and including this one") { |v| options[:through_stage] = v.to_sym }

        opts.on("--dump-raw PATH", "Write raw payload to PATH after extract ('-' = stdout)") { |v| options[:dump_raw] = v }
        opts.on("--from-raw PATH", "Load raw payload from PATH, skip connect + extract") { |v| options[:from_raw] = v }
        opts.on("--dump-normalized PATH", "Write normalized payload to PATH after normalize") { |v| options[:dump_normalized] = v }
        opts.on("--from-normalized PATH", "Load normalized payload from PATH, skip everything upstream") { |v| options[:from_normalized] = v }

        opts.on("--secrets BACKEND", "Secret backend (#{Secrets.registered.join("|")})") { |v| options[:secrets_backend] = v.to_sym }
        opts.on("--secrets-file PATH", "Path for plain_file backend") { |v| options[:secrets_file] = v }
        opts.on("--secrets-fd N", Integer, "Inherited fd carrying a dotenv payload for the inline_fd backend") { |v| options[:secrets_fd] = v }

        opts.on("--export NAME", "Add an exporter (#{Exporters.registered.join("|")}); repeatable") do |v|
          options[:exporters] << { name: v.to_sym, options: {} }
        end

        # Per-exporter options attach to the most recently declared --export.
        opts.on("--export-path PATH", "Path for the last-declared exporter") { |v| attach(options, :path, v) }
        opts.on("--export-url URL", "URL for the http exporter") { |v| attach(options, :url, v) }
        opts.on("--export-token TOKEN", "Bearer token for the http exporter") { |v| attach(options, :token, v) }
        opts.on("--export-method METHOD", "HTTP method (POST|PUT) for the http exporter") { |v| attach(options, :method, v) }
        opts.on("--export-content-type TYPE", "Content-Type for the http exporter") { |v| attach(options, :content_type, v) }
        opts.on("--export-header KV", "Extra header KEY=VAL for the http exporter (repeatable)") do |v|
          k, val = v.split("=", 2)
          raise UserError, "--export-header expects KEY=VALUE" unless k && val
          headers = (last_exporter(options)[:options][:headers] ||= {})
          headers[k] = val
        end

        opts.on("--lint", "Statically validate the --workflow (schema, extract/normalize/ext ruby, api_client, credential + secret references) without launching Chrome") { options[:lint] = true }

        opts.on("--schema-json", "Print the workflow dialect (actions, keys, plan verbs) as JSON and exit") { options[:schema_json] = true }

        opts.on("--compile-recording PATH", "Compile a recording.jsonl into a draft connect: pipeline (YAML to stdout). A DRAFT, not a finished provider — read, edit, then --lint it.") { |v| options[:compile_recording] = v }
        opts.on("--init", "Bootstrap a stub workflow YAML at --out/--workflow (default workflow.yml): prompts for the initial login URL, the secret names the login needs, and an optional post-login (ready) URL. Refuses to overwrite. Then --recording it.") { options[:init] = true }
        opts.on("--url URL", "Initial login URL for --init (skips the interactive prompts)") { |v| options[:url] = v }
        opts.on("--secret NAME", "A secret name the login needs, for --init's secrets: block (repeatable; names only, never values)") { |v| options[:init_secrets] << v }
        opts.on("--ready-url URL", "Post-login URL that confirms success, for --init (scaffolds a wait_url)") { |v| options[:ready_url] = v }
        opts.on("--out PATH", "Write --compile-recording / --init output to PATH instead of stdout/workflow.yml (compile output is refused inside a git work tree)") { |v| options[:out] = v }

        opts.on("--purge", "Remove all freentonic data (Chrome profile, Keychain entries, temp files)") { options[:purge] = true }
        opts.on("--force", "Skip confirmation prompt (use with --purge)") { options[:force] = true }

        opts.on("--interactive", "Browse mode: run only the workflow's `connect` phase (URL navigation), then idle until SIGTERM. Lets the operator interact with the bank manually via VNC to warm a fresh fingerprint or solve 2FA.") { options[:interactive] = true }
        opts.on("--recording", "Recording mode: launch CDP Chrome at the workflow's initial URL, idle until SIGTERM, and capture click/change/submit/navigate events to <run_dir>/recording.jsonl. Used to bootstrap or repair a workflow YAML by walking the bank's UI by hand. Mutually exclusive with --interactive.") { options[:recording] = true }

        opts.on("--step", "Step mode: launch Chrome at the workflow's initial URL and hold it open, then read one action per line (JSONL) from stdin, run each, and print a result envelope to stdout (a failed action attaches a page observation). The observe→act→observe authoring loop. Closes on EOF/`quit`. Mutually exclusive with --interactive/--recording.") { options[:step] = true }

        opts.on("-h", "--help") { puts opts; exit 0 }
        opts.on("--version") { puts "freentonic #{Freentonic::VERSION}"; exit 0 }
      end

      parser.parse!(argv)
      options
    rescue OptionParser::ParseError => e
      raise UserError, e.message
    end

    def attach(options, key, value)
      last_exporter(options)[:options][key] = value
    end

    def last_exporter(options)
      options[:exporters].last or raise UserError,
        "--export-* flag before --export NAME (declare the exporter first)"
    end

    def validate!(options)
      if options[:lint]
        raise UserError, "--lint cannot be combined with --purge" if options[:purge]
        raise UserError, "--lint requires --workflow PATH" unless options[:workflow]
        return
      end

      if options[:purge]
        pipeline_flags = %i[workflow from_raw from_normalized only_stage through_stage dump_raw dump_normalized]
        conflict = pipeline_flags.find { |f| options[f] }
        raise UserError, "--purge cannot be combined with --#{conflict.to_s.tr("_", "-")}" if conflict
        raise UserError, "--export cannot be combined with --purge" unless options[:exporters].empty?
        return
      end

      if options[:force]
        raise UserError, "--force is only valid with --purge"
      end

      unless options[:workflow] || options[:from_raw] || options[:from_normalized]
        raise UserError, "missing --workflow PATH"
      end

      if options[:only_stage] && options[:through_stage]
        raise UserError, "--only-stage and --through are mutually exclusive"
      end

      # --interactive forces the engine to run only Connect. Combining
      # it with stage-isolation, serialized-input, or output-producing
      # flags would either contradict that (--only-stage / --through),
      # yield an empty pipeline (--from-raw / --from-normalized, which
      # add :connect to the engine's skip set), or silently request
      # artifacts that the bypassed Extract/Normalize/Export stages
      # would have produced (--dump-raw / --dump-normalized /
      # --export). Reject up-front rather than letting the engine
      # quietly run zero stages or quietly drop the output flags.
      if options[:interactive]
        conflicting = %i[only_stage through_stage from_raw from_normalized dump_raw dump_normalized].find { |f| options[f] }
        if conflicting
          raise UserError,
            "--interactive cannot be combined with --#{conflicting.to_s.tr('_', '-')}"
        end
        unless options[:exporters].empty?
          raise UserError, "--interactive cannot be combined with --export"
        end
      end

      if options[:recording]
        if options[:interactive]
          raise UserError, "--recording cannot be combined with --interactive (pick one)"
        end
        conflicting = %i[only_stage through_stage from_raw from_normalized dump_raw dump_normalized].find { |f| options[f] }
        if conflicting
          raise UserError,
            "--recording cannot be combined with --#{conflicting.to_s.tr('_', '-')}"
        end
        unless options[:exporters].empty?
          raise UserError, "--recording cannot be combined with --export"
        end
      end

      # --step holds Chrome open and drives it a step at a time from the
      # workflow's secret/error-signal context, so it needs --workflow and,
      # like --interactive/--recording, stops the pipeline at Connect — the
      # same output-producing / stage-isolation flags contradict it.
      if options[:step]
        raise UserError, "--step requires --workflow PATH" unless options[:workflow]
        if options[:interactive]
          raise UserError, "--step cannot be combined with --interactive (pick one)"
        end
        if options[:recording]
          raise UserError, "--step cannot be combined with --recording (pick one)"
        end
        conflicting = %i[only_stage through_stage from_raw from_normalized dump_raw dump_normalized].find { |f| options[f] }
        if conflicting
          raise UserError,
            "--step cannot be combined with --#{conflicting.to_s.tr('_', '-')}"
        end
        unless options[:exporters].empty?
          raise UserError, "--step cannot be combined with --export"
        end
      end

      # Stage-isolation flags that legitimately stop the pipeline before
      # the Export stage runs — no exporter is needed for these because
      # there's nothing to export. Both --only-stage and --through count.
      # --interactive also stops at Connect (its whole purpose).
      pre_export_stage = ->(s) { s == :connect || s == :extract }
      stops_before_export = pre_export_stage.call(options[:only_stage]) ||
                            pre_export_stage.call(options[:through_stage]) ||
                            options[:interactive] ||
                            options[:recording] ||
                            options[:step]

      if options[:exporters].empty? && !stops_before_export &&
         options[:dump_raw].nil? && options[:dump_normalized].nil?
        raise UserError, "no exporters configured — pass --export NAME or --dump-raw / --dump-normalized"
      end
    end

    def run_schema_json(_options)
      require_relative "schema_export"
      @stdout.puts Freentonic::SchemaExport.to_json
      0
    end

    # Bootstrap a minimal workflow YAML so `--recording`/`--step` (which both
    # require a --workflow with an initial URL to launch at) have something to
    # point at for a brand-new provider. Prompts for the login URL unless --url
    # is given. Writes nothing over an existing file. Unlike --compile-recording,
    # the stub has no captured PII, so it is NOT refused inside a git work tree —
    # a stub is meant to grow into a committed provider.
    def run_init(options)
      path = File.expand_path(init_output_path(options))
      if File.exist?(path)
        raise UserError, "--init: #{path} already exists — refusing to overwrite. " \
                         "Delete it, or pass --out PATH for a new file."
      end

      # --url present ⇒ non-interactive: take everything from flags. Otherwise
      # prompt for the three pieces on stdin.
      if options[:url]
        url         = options[:url]
        secret_names = normalize_secret_names(options[:init_secrets])
        ready_url   = options[:ready_url]
      else
        url          = prompt("Initial login URL (https://...): ")
        secret_names = normalize_secret_names(
          split_names(prompt("Secret names the login needs, space-separated " \
                             "(names only, e.g. USER_ID USER_PIN), blank for none: "))
        )
        ready_url    = presence(prompt("Post-login URL that confirms success (optional, blank to skip): "))
      end

      url = url.to_s.strip
      raise UserError, "--init: an initial login URL is required (pass --url or answer the prompt)" if url.empty?
      validate_http_url!(url, "initial")
      ready_url = presence(ready_url)
      validate_http_url!(ready_url, "ready") if ready_url

      # 0600 to match the workspace's recording/dump discipline; the stub is
      # created fresh (guarded above) and NOFOLLOW refuses a planted symlink.
      File.open(path, secure_write_flags(File::TRUNC), 0o600) do |f|
        f.chmod(0o600)
        f.write(init_stub_yaml(url, secret_names, ready_url))
      end
      @stdout.puts "Wrote stub workflow to #{path}#{secret_names.empty? ? "" : " (#{secret_names.length} secret name(s))"}."
      @stdout.puts "Next: freentonic --recording --workflow #{init_output_path(options)}"
      0
    end

    def init_output_path(options)
      options[:out] || options[:workflow] || "workflow.yml"
    end

    def prompt(label)
      @stderr.print label
      @stderr.flush
      @stdin.gets
    end

    def presence(str)
      s = str.to_s.strip
      s.empty? ? nil : s
    end

    def split_names(str)
      str.to_s.split(/[\s,]+/).reject(&:empty?)
    end

    # No whitespace anywhere: the URL is written into the stub verbatim, and a
    # newline would end the YAML line (or comment) it sits on.
    def validate_http_url!(url, which)
      return if url.to_s.strip.match?(%r{\Ahttps?://\S+\z}i)
      raise UserError, "--init: #{which} URL must be an http:// or https:// URL with no spaces " \
                       "(got #{url.to_s.strip.inspect})"
    end

    # Keep only valid secret-name tokens (an identifier), deduped in order.
    # A stray value pasted in a name field is dropped rather than written —
    # secret VALUES never belong in a workflow file (they arrive at runtime
    # via --secrets). A token that isn't a clean identifier is skipped with a
    # note so the operator notices.
    def normalize_secret_names(tokens)
      seen = []
      Array(tokens).each do |raw|
        name = raw.to_s.strip
        next if name.empty?
        unless name.match?(/\A[A-Za-z][A-Za-z0-9_]*\z/)
          @stderr.puts "--init: skipping #{name.inspect} — not a valid secret name (letters, digits, underscore)"
          next
        end
        seen << name unless seen.include?(name)
      end
      seen
    end

    # A double-quoted YAML scalar body: backslash-escape the two characters a
    # double-quoted scalar can't hold literally. URLs/prompts here won't
    # contain a newline (inputs are single-line), so no block-scalar handling.
    def yaml_dq(str)
      %("#{str.to_s.gsub(/[\\"]/) { |c| "\\#{c}" }}")
    end

    def init_stub_yaml(url, secret_names, ready_url)
      out = +"version: 1\n\n"
      out << "# Stub created by `freentonic --init`. Set config.key, then record the\n"
      out << "# login by hand with `freentonic --recording` and turn the capture into a\n"
      out << "# draft with `freentonic --compile-recording recording.jsonl`.\n\n"
      out << "config:\n  key: REPLACE_ME\n\n"

      unless secret_names.empty?
        out << "secrets:\n"
        secret_names.each do |name|
          out << "  #{name}:\n"
          out << "    prompt: #{yaml_dq("REPLACE_ME: describe #{name}")}\n"
        end
        out << "\n"
      end

      out << "pipeline:\n  - connect\n\n"
      out << "phases:\n  connect:\n"
      out << "    - action: navigate\n      url: #{yaml_dq(url)}\n"

      if ready_url
        out << "    # After your login steps, confirm success by waiting for the\n"
        out << "    # post-login URL (move this below the steps you add):\n"
        out << "    #   - action: wait_url\n"
        out << "    #     includes: #{yaml_dq(url_path_tail(ready_url))}\n"
      end
      out
    end

    # The distinctive tail of a URL for a wait_url `includes:` — the path, or
    # the host when the path is empty/root.
    def url_path_tail(url)
      require "uri"
      parsed = URI.parse(url.to_s.strip)
      tail = parsed.path.to_s
      tail = parsed.host.to_s if tail.empty? || tail == "/"
      tail.empty? ? url.to_s.strip : tail
    rescue URI::InvalidURIError
      url.to_s.strip
    end

    def run_compile_recording(options)
      require_relative "recording_compiler"

      recording_path = File.expand_path(options[:compile_recording])
      # A typo'd path is a common user error. Surface it as a friendly
      # UserError (exit 1) like every other CLI file-input path, rather than
      # letting Errno::ENOENT/EACCES escape run's rescue as a raw backtrace.
      unless File.file?(recording_path)
        raise UserError, "--compile-recording: no such file: #{recording_path}"
      end
      unless File.readable?(recording_path)
        raise UserError, "--compile-recording: cannot read file: #{recording_path}"
      end

      if (out = options[:out]) && inside_git_worktree?(out)
        raise UserError,
              "--compile-recording: refusing to write --out #{File.expand_path(out).inspect} — " \
              "it is inside a git work tree. The draft can contain a username literal from the " \
              "recording; write it to /tmp (or another dir outside the repo), review it, then copy it in."
      end

      yaml = RecordingCompiler.new(
        recording_path: recording_path,
        stdout: @stdout,
        stderr: @stderr
      ).compile

      if (out = options[:out])
        # 0600: the draft can carry a captured username literal — match the
        # secret-file discipline used for recordings and request dumps. The
        # mode argument only fixes permissions on files this open *creates*,
        # so we also chmod after opening to force 0600 on a pre-existing
        # (possibly world-readable) target, and pass NOFOLLOW so a symlink
        # planted at the path is not followed and overwritten.
        File.open(File.expand_path(out), secure_write_flags(File::TRUNC), 0o600) do |f|
          f.chmod(0o600)
          f.write(yaml)
        end
        @stdout.puts "Wrote draft workflow to #{File.expand_path(out)} — review it, then `freentonic --lint` it."
      else
        @stdout.print(yaml)
      end
      0
    end

    # Base open flags for writing a file that may hold PII/secrets: write-only,
    # create if absent, plus O_NOFOLLOW where the platform provides it so a
    # symlink planted at the target is refused instead of followed. Callers add
    # the mode-specific flag (TRUNC to overwrite, APPEND to append).
    def secure_write_flags(mode_flag)
      flags = File::WRONLY | File::CREAT | mode_flag
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      flags
    end

    # True when `path` would land inside a git work tree (linked worktrees
    # included). Uses `git rev-parse --is-inside-work-tree` via array-form
    # Open3 (no shell string, invariant 3) run from the nearest existing
    # ancestor of the target path. Any failure (git absent, path unresolvable)
    # is treated as "not inside a repo" — the check is a speed bump.
    def inside_git_worktree?(path)
      dir = File.expand_path(path)
      dir = File.dirname(dir) until File.directory?(dir) || File.dirname(dir) == dir
      return false unless File.directory?(dir)

      stdout_str, _stderr_str, status = Open3.capture3(
        "git", "rev-parse", "--is-inside-work-tree", chdir: dir
      )
      status.success? && stdout_str.strip == "true"
    rescue StandardError
      false
    end

    def run_lint(options)
      require_relative "linter"
      Linter.new(
        workflow_path: File.expand_path(options[:workflow]),
        stdout: @stdout,
        stderr: @stderr
      ).run
    end

    def execute(options)
      if options[:purge]
        require_relative "purge"
        Purge.new(stdout: @stdout, stderr: @stderr, force: options[:force]).run
        return
      end

      source = options[:workflow] ? Source.new(workflow_path: File.expand_path(options[:workflow])) : nil

      secret_store = build_secret_store(options)
      secret_resolver = SecretResolver.new(secret_store: secret_store, stdout: @stdout, stderr: @stderr)

      exporters = options[:exporters].map { |cfg| Exporters.build(cfg[:name], cfg[:options]) }

      context = {
        source: source,
        stdout: @stdout,
        stderr: @stderr,
        reporter: Reporter.build(stdout: @stdout),
        secret_resolver: secret_resolver,
        lookback_days: options[:lookback_days] || source&.default_lookback_days || 14,
        isolated: options[:isolated],
        reset_profile: options[:reset_profile],
        headless: options[:headless],
        no_sandbox: options[:no_sandbox],
        cdp_port: options[:cdp_port],
        only_stage: options[:only_stage],
        through_stage: options[:through_stage],
        dump_raw: options[:dump_raw],
        from_raw: options[:from_raw],
        dump_normalized: options[:dump_normalized],
        from_normalized: options[:from_normalized],
        exporters: exporters,
        interactive: options[:interactive],
        recording: options[:recording],
        step: options[:step]
      }

      # Step mode speaks JSONL: every result envelope must land on stdout with
      # nothing else. Route the runner's / stage's human log lines to stderr
      # (context[:stdout]) and silence the pretty reporter, leaving stdout as a
      # pristine one-envelope-per-line channel the server proxy can read. The
      # StepSession writes envelopes to context[:step_output].
      if options[:step]
        context[:step_output] = @stdout
        context[:stdout]      = @stderr
        context[:reporter]    = Reporter.null
      end

      Engine.new(context: context).run
    end

    def build_secret_store(options)
      name = options[:secrets_backend] || Secrets.default_name

      # Validation matrix for the three secret-source flags. `--secrets-fd`
      # only makes sense alongside `--secrets inline_fd`; covers both
      # `--secrets-fd N` alone (default backend != inline_fd) and any
      # other-backend + --secrets-fd combo.
      if options[:secrets_fd] && name != :inline_fd
        raise UserError, "--secrets-fd requires --secrets inline_fd"
      end
      if name == :inline_fd && options[:secrets_file]
        raise UserError, "--secrets inline_fd does not take --secrets-file"
      end

      # The CLI maps its flags to each backend's options, but construction
      # always goes through the registry (Secrets.build) so a third-party
      # backend registered under one of these names is honored too.
      case name
      when :plain_file
        path = options[:secrets_file] or raise UserError, "--secrets plain_file requires --secrets-file PATH"
        @stderr.puts(Secrets::PlainFile.insecure_banner)
        Secrets.build(:plain_file, path: path)
      when :inline_fd
        fd = options[:secrets_fd] or raise UserError, "--secrets inline_fd requires --secrets-fd N"
        Secrets.build(:inline_fd, fd: fd)
      else
        Secrets.build(name)
      end
    end
  end
end
