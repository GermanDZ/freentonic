# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "freentonic/invoke_request"
require "freentonic/invoke_runner"

class InvokeRunnerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("freentonic-runner-test-")
    @workflows_dir       = File.join(@root, "workflows")
    @runs_dir            = File.join(@root, "runs")
    @chrome_profile_root = File.join(@root, "chrome")
    @vnc_dir             = File.join(@root, "vnc")
    @vnc_password_file   = File.join(@vnc_dir, "password")
    FileUtils.mkdir_p([@workflows_dir, @runs_dir, @chrome_profile_root, @vnc_dir])

    @workflow_rel = "acme/workflow.yml"
    @workflow_abs = File.join(@workflows_dir, @workflow_rel)
    FileUtils.mkdir_p(File.dirname(@workflow_abs))
    File.write(@workflow_abs, "version: 1\n")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  # The stub masquerades as bin/freentonic. Writes its argv, env, the
  # contents of the inherited inline-secrets fd (when present), and a
  # snapshot of the pre-spawn VNC passwdfile into $FREENTONIC_RUN_DIR/stub/
  # so the test can assert on them after the run finishes.
  STUB_HEADER = <<~'BASH'
    #!/bin/bash
    set +e
    R="${FREENTONIC_RUN_DIR}/stub"
    mkdir -p "$R"
    printf '%s\n' "$@" > "$R/argv"
    env | sort > "$R/env"

    # Find --secrets-file PATH in argv (paired, preserves spaces in values).
    secrets_path=""
    secrets_fd=""
    prev=""
    for arg in "$@"; do
      case "$prev" in
        --secrets-file) secrets_path="$arg" ;;
        --secrets-fd)   secrets_fd="$arg" ;;
      esac
      prev="$arg"
    done

    if [ -n "$secrets_path" ] && [ -f "$secrets_path" ]; then
      stat -c "%a" "$secrets_path" 2>/dev/null > "$R/secrets_mode" || \
      stat -f "%OLp" "$secrets_path"           > "$R/secrets_mode"
      cp "$secrets_path" "$R/secrets_contents"
    fi

    # Drain the inherited inline-secrets fd. The runner always picks fd 3,
    # so hardcode it (bash redirection numbers must be literal).
    if [ -n "$secrets_fd" ]; then
      cat <&3 > "$R/secrets_contents"
    fi

    # Snapshot the vnc passwdfile that the server wrote BEFORE spawning us.
    # Tests compare this against the request's vnc_password to verify the
    # pre-spawn write landed. We look at $STUB_VNC_FILE (set by the test);
    # the child's scoped ENV doesn't include it, so the test passes the path
    # via a sentinel file in @root that the stub knows where to find.
    if [ -f "${FREENTONIC_RUN_DIR}/../../vnc/password" ]; then
      cp "${FREENTONIC_RUN_DIR}/../../vnc/password" "$R/vnc_password_at_spawn"
      stat -c "%a" "${FREENTONIC_RUN_DIR}/../../vnc/password" 2>/dev/null > "$R/vnc_password_mode" || \
      stat -f "%OLp" "${FREENTONIC_RUN_DIR}/../../vnc/password"           > "$R/vnc_password_mode"
    fi
  BASH

  def write_stub(behavior)
    path = File.join(@root, "stub-#{rand(1_000_000)}.sh")
    File.write(path, STUB_HEADER + "\n" + behavior + "\n")
    File.chmod(0o755, path)
    path
  end

  def build_runner(stub_path)
    Freentonic::InvokeRunner.new(
      workflows_dir:       @workflows_dir,
      runs_dir:            @runs_dir,
      chrome_profile_root: @chrome_profile_root,
      freentonic_cmd:      ["/bin/bash", stub_path],
      artifact_root:       @root,
      vnc_password_file:   @vnc_password_file
    )
  end

  def build_request(overrides = {})
    body = {
      "run_id"      => "test-run-#{rand(1_000_000)}",
      "workflow"    => @workflow_rel,
      "profile_key" => "acme__tenant",
      "credentials" => { "inline" => { "USER" => "alice", "PW" => "s3cret" } },
      "export" => {
        "mode"  => "http",
        "url"   => "http://example.com/push",
        "token" => "bearer-xyz"
      },
      "timeout_sec" => 30
    }.merge(overrides.transform_keys(&:to_s))
    Freentonic::InvokeRequest.from_hash(body, workflows_dir: @workflows_dir)
  end

  def read_stub(run_dir, name)
    path = File.join(run_dir, "stub", name)
    File.exist?(path) ? File.read(path) : nil
  end

  # ─── happy path ───

  def test_runs_stub_and_captures_argv_and_secrets
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request
    result = runner.run(request)

    assert_equal 0, result.exit_code
    assert_nil result.error_kind, "success should carry error_kind=nil"
    run_dir = File.join(@runs_dir, request.run_id)

    argv = read_stub(run_dir, "argv")
    assert_includes argv, "--workflow\n"
    assert_includes argv, "--secrets\n"
    assert_includes argv, "inline_fd\n"
    assert_includes argv, "--secrets-fd\n"
    assert_includes argv, "3\n", "inline-cred runs hand the dotenv over on fd 3"
    refute_includes argv, "plain_file\n",
      "inline credentials must not route through the plain_file backend"
    refute_includes argv, "--secrets-file\n",
      "inline credentials must not surface a file path"
    assert_includes argv, "--export\n"
    assert_includes argv, "http\n"
    assert_includes argv, "--export-url\n"
    assert_includes argv, "http://example.com/push\n"

    refute_includes argv, "--export-token\n",
      "token must not appear on argv (it's passed via ENV only)"
    refute_includes argv, "bearer-xyz\n",
      "token value must not appear on argv"
  end

  # ─── step session (open/close over real pipes, no Chrome) ───

  # A trivial ruby "--step child": announces ready, then echoes an envelope per
  # stdin line and exits on EOF. Stands in for `freentonic --step` so the real
  # Process.spawn pipe wiring + close/reap are exercised without a browser.
  def write_ruby_step_stub(behavior)
    path = File.join(@root, "step-stub-#{rand(1_000_000)}.rb")
    File.write(path, <<~RUBY)
      require "json"
      $stdout.sync = true
      File.write(File.join(ENV.fetch("FREENTONIC_RUN_DIR"), "argv"), ARGV.join("\\n"))
      puts JSON.generate("ready" => true, "url" => "https://stub/login")
      #{behavior}
    RUBY
    path
  end

  def build_step_runner(stub_path)
    Freentonic::InvokeRunner.new(
      workflows_dir:       @workflows_dir,
      runs_dir:            @runs_dir,
      chrome_profile_root: @chrome_profile_root,
      freentonic_cmd:      [RbConfig.ruby, stub_path],
      artifact_root:       @root,
      vnc_password_file:   @vnc_password_file
    )
  end

  def test_open_step_session_returns_a_working_handle_and_close_reaps_it
    stub = write_ruby_step_stub(<<~'RUBY')
      while (line = $stdin.gets)
        step = (JSON.parse(line) rescue { "raw" => line.strip })
        puts JSON.generate("ok" => true, "got" => step)
      end
    RUBY
    runner  = build_step_runner(stub)
    request = build_request("step" => true)

    started = nil
    handle = runner.open_step_session(request) { |pid, pgid| started = [pid, pgid] }
    begin
      ready = JSON.parse(handle.stdout.gets)
      assert_equal true, ready["ready"]
      assert_equal [handle.pid, handle.pgid], started

      handle.stdin.puts(JSON.generate("action" => "click"))
      handle.stdin.flush
      env = JSON.parse(handle.stdout.gets)
      assert_equal true, env["ok"]
      assert_equal({ "action" => "click" }, env["got"])
    ensure
      runner.close_step_session(handle)
    end

    # Graceful close: stdin EOF ended the child's loop; it is reaped and gone.
    assert_raises(Errno::ESRCH) { Process.kill(0, handle.pid) }
    # And VNC was relocked to an unreachable sentinel on close.
    assert_equal 64, File.read(@vnc_password_file).length
  end

  def test_open_step_session_passes_step_and_omits_export_on_argv
    stub = write_ruby_step_stub("$stdin.gets") # block on one line, don't spin
    runner  = build_step_runner(stub)
    request = build_request("step" => true) # build_request's body includes an export block
    handle  = runner.open_step_session(request)
    begin
      handle.stdout.gets # consume ready (also flushes after the argv write)
      argv = File.read(File.join(@runs_dir, request.run_id, "argv")).split("\n")
      assert_includes argv, "--step"
      refute_includes argv, "--export", "step mode short-circuits at Connect — no exporter"
      assert_includes argv, "--workflow"
    ensure
      handle.stdin.close rescue nil
      runner.close_step_session(handle)
    end
  end

  # Defense in depth: even if a malformed run_id slipped past InvokeRequest's
  # pattern (which now rejects "."/".."), the runner must refuse to mkdir
  # outside @runs_dir rather than truncate the workspace or glob other tenants.
  def test_run_rejects_run_id_escaping_runs_dir
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request
    request.define_singleton_method(:run_id) { ".." }
    err = assert_raises(Freentonic::InvokeError) { runner.run(request) }
    assert_equal 400, err.status_code
    refute Dir.exist?(File.join(@runs_dir, "prompts")),
      "escaping run_id must not create dirs at the runs-dir root"
  end

  def test_export_token_passed_via_child_env
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request
    result = runner.run(request)
    run_dir = File.join(@runs_dir, request.run_id)

    env = read_stub(run_dir, "env")
    assert_includes env, "FREENTONIC_HTTP_TOKEN=bearer-xyz"
    assert_includes env, "FREENTONIC_RUN_ID=#{request.run_id}"
    assert_includes env, "FREENTONIC_CHROME_PROFILE_DIR=#{File.join(@chrome_profile_root, "acme__tenant")}"

    # unsetenv_others: true should have stripped everything not explicitly set.
    refute_match(/^USER=/, env)
    refute_match(/^SHELL=/, env)

    assert_equal 0, result.exit_code
  end

  # Regression: unsetenv_others strips everything not in build_env's
  # whitelist, including GEM_HOME/GEM_PATH — so a gem installed outside
  # Ruby's compiled-in default path (e.g. the image's optional tzinfo) was
  # invisible to the workflow subprocess even though it resolves fine in an
  # interactive shell or a plain `docker exec`.
  def test_gem_env_passed_through_to_child_when_set
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request

    original_gem_home, original_gem_path = ENV["GEM_HOME"], ENV["GEM_PATH"]
    ENV["GEM_HOME"] = "/usr/local/bundle"
    ENV["GEM_PATH"] = "/usr/local/bundle"
    begin
      runner.run(request)
    ensure
      ENV["GEM_HOME"] = original_gem_home
      ENV["GEM_PATH"] = original_gem_path
    end
    run_dir = File.join(@runs_dir, request.run_id)

    env = read_stub(run_dir, "env")
    assert_includes env, "GEM_HOME=/usr/local/bundle"
    assert_includes env, "GEM_PATH=/usr/local/bundle"
  end

  def test_inline_secrets_handed_over_fd3_to_child
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request
    runner.run(request)
    run_dir = File.join(@runs_dir, request.run_id)

    contents = read_stub(run_dir, "secrets_contents").to_s
    assert_includes contents, "USER=alice"
    assert_includes contents, "PW=s3cret"
    assert_nil read_stub(run_dir, "secrets_mode"),
      "no on-disk secrets file should exist — the fd path bypasses the filesystem"
  end

  def test_log_file_is_written_with_mode_0600
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request
    runner.run(request)
    log_path = File.join(@runs_dir, request.run_id, "log")
    mode = File.stat(log_path).mode & 0o777
    assert_equal 0o600, mode,
      "log file must be owner-only (got #{mode.to_s(8).rjust(3, "0")})"
  end

  def test_artifact_list_includes_files_written_during_run
    stub = write_stub(%(touch "$FREENTONIC_RUN_DIR/evidence.png"\nexit 0))
    runner = build_runner(stub)
    request = build_request
    result = runner.run(request)

    rel_paths = result.artifacts.map(&:path)
    assert rel_paths.any? { |p| p.end_with?("evidence.png") }, "expected evidence.png in #{rel_paths.inspect}"
    assert rel_paths.any? { |p| p.end_with?("log") }, "expected log in #{rel_paths.inspect}"
  end

  # ─── child exit / crash ───

  def test_nonzero_exit_is_reported
    stub = write_stub("exit 42")
    runner = build_runner(stub)
    request = build_request
    result = runner.run(request)
    assert_equal 42, result.exit_code
    assert_equal "unknown", result.error_kind
  end

  def test_exit_1_classified_as_user_error
    stub = write_stub("exit 1")
    result = build_runner(stub).run(build_request)
    assert_equal 1, result.exit_code
    assert_equal "user_error", result.error_kind
  end

  def test_exit_2_classified_as_export_error
    stub = write_stub("exit 2")
    result = build_runner(stub).run(build_request)
    assert_equal 2, result.exit_code
    assert_equal "export_error", result.error_kind
  end

  def test_signal_death_classified_as_signal
    # bash `kill -TERM $$` kills the shell itself. The parent sees a
    # signaled status distinct from any watchdog action (timed_out=false).
    stub = write_stub("kill -TERM $$")
    result = build_runner(stub).run(build_request)
    assert_equal "signal", result.error_kind
    assert_operator result.exit_code, :>=, 128
  end

  # ─── timeout ───

  def test_timeout_terminates_child_and_reports_warning
    stub = write_stub("sleep 30\nexit 0")
    runner = build_runner(stub)
    # Use the request body directly to pass a sub-MIN timeout for the test.
    req_body = {
      "run_id"      => "timeout-run-#{rand(1_000_000)}",
      "workflow"    => @workflow_rel,
      "profile_key" => "acme__tenant",
      "credentials" => { "inline" => { "USER" => "a", "PW" => "b" } },
      "timeout_sec" => 1
    }
    request = Freentonic::InvokeRequest.from_hash(req_body, workflows_dir: @workflows_dir)

    t0 = Time.now
    result = runner.run(request)
    elapsed = Time.now - t0

    refute_equal 0, result.exit_code, "timed-out child should not exit 0"
    assert result.warnings.any? { |w| w.include?("timeout") }, "expected timeout warning: #{result.warnings.inspect}"
    assert elapsed < 15, "expected child to exit fast on SIGTERM, took #{elapsed}s"
    assert_equal "timeout", result.error_kind,
      "timeout must take precedence over the signal that killed the child"
  end

  def test_classify_error_unit
    assert_nil             Freentonic::InvokeRunner.classify_error(0, false, false)
    assert_equal "timeout",      Freentonic::InvokeRunner.classify_error(143, true,  true)
    assert_equal "signal",       Freentonic::InvokeRunner.classify_error(134, false, true)
    assert_equal "user_error",   Freentonic::InvokeRunner.classify_error(1,   false, false)
    assert_equal "export_error", Freentonic::InvokeRunner.classify_error(2,   false, false)
    assert_equal "unknown",      Freentonic::InvokeRunner.classify_error(42,  false, false)
  end

  # ─── interactive (browse mode) plumbing ───

  def test_interactive_flag_passed_to_child
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request("interactive" => true)
    runner.run(request)
    run_dir = File.join(@runs_dir, request.run_id)

    argv = read_stub(run_dir, "argv")
    assert_includes argv, "--interactive\n",
      "interactive=true must surface as --interactive on the child argv"
  end

  def test_interactive_omits_export_argv
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    # `build_request` defaults to an http export block. Interactive
    # mode skips export validation in InvokeRequest, so request.export
    # ends up nil, and no --export* args should land on argv. (The
    # engine short-circuits at Connect, so even if argv carried them
    # the exporter would never fire — but plumbing them would still
    # trip the CLI's "no exporters configured" / argv validation.)
    request = build_request("interactive" => true)
    runner.run(request)
    run_dir = File.join(@runs_dir, request.run_id)

    argv = read_stub(run_dir, "argv")
    refute_includes argv, "--export\n",
      "interactive mode must not emit --export on argv"
    refute_includes argv, "--export-url\n",
      "interactive mode must not emit --export-url on argv"
    refute_includes argv, "--export-token\n"
    refute_includes argv, "http://example.com/push\n"
  end

  def test_non_interactive_still_emits_export_argv
    # Guard against accidentally regressing the default path while
    # touching the interactive branch.
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request # interactive defaults to false
    runner.run(request)
    run_dir = File.join(@runs_dir, request.run_id)

    argv = read_stub(run_dir, "argv")
    refute_includes argv, "--interactive\n"
    assert_includes argv, "--export\n"
    assert_includes argv, "http\n"
  end

  # ─── traversal & missing workflow already covered in InvokeRequestTest ───

  # ─── chrome profile ───

  def test_chrome_profile_subdir_created
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request
    runner.run(request)

    expected = File.join(@chrome_profile_root, "acme__tenant")
    assert Dir.exist?(expected), "expected profile subdir at #{expected}"
  end

  # ─── vnc password rotation ───

  def test_vnc_password_written_before_spawn_when_provided
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request(vnc_password: "operator-pw-2026")
    runner.run(request)

    run_dir = File.join(@runs_dir, request.run_id)
    snapshot = read_stub(run_dir, "vnc_password_at_spawn").to_s
    assert_equal "operator-pw-2026", snapshot,
      "child process should have seen the operator-supplied vnc password"

    mode = read_stub(run_dir, "vnc_password_mode").to_s.strip
    assert_equal "600", mode, "vnc passwdfile must be owner-only"
  end

  def test_vnc_password_random_unreachable_when_absent
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request  # no vnc_password in overrides
    runner.run(request)

    run_dir = File.join(@runs_dir, request.run_id)
    snapshot = read_stub(run_dir, "vnc_password_at_spawn").to_s
    assert_match(/\A[0-9a-f]{64}\z/, snapshot,
      "without vnc_password, the passwdfile should carry an unreachable random value")
  end

  def test_vnc_password_overwritten_in_ensure_block
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request(vnc_password: "during-run-pw")
    runner.run(request)

    run_dir = File.join(@runs_dir, request.run_id)
    at_spawn = read_stub(run_dir, "vnc_password_at_spawn").to_s
    after_run = File.read(@vnc_password_file)

    assert_equal "during-run-pw", at_spawn
    refute_equal at_spawn, after_run,
      "ensure block should overwrite the passwdfile; the operator password must not linger"
    assert_match(/\A[0-9a-f]{64}\z/, after_run,
      "post-run sentinel should be a 64-hex-char unreachable value")
  end
end
