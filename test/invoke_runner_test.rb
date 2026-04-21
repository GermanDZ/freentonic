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
    @tmpfs_dir           = File.join(@root, "tmpfs")
    @chrome_profile_root = File.join(@root, "chrome")
    FileUtils.mkdir_p([@workflows_dir, @runs_dir, @tmpfs_dir, @chrome_profile_root])

    @workflow_rel = "acme/workflow.yml"
    @workflow_abs = File.join(@workflows_dir, @workflow_rel)
    FileUtils.mkdir_p(File.dirname(@workflow_abs))
    File.write(@workflow_abs, "version: 1\n")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  # The stub masquerades as bin/freentonic. Writes its argv, env, and the
  # contents/mode of its --secrets-file into $FREENTONIC_RUN_DIR/stub/ so
  # the test can assert on them after the run finishes.
  STUB_HEADER = <<~'BASH'
    #!/bin/bash
    set +e
    R="${FREENTONIC_RUN_DIR}/stub"
    mkdir -p "$R"
    printf '%s\n' "$@" > "$R/argv"
    env | sort > "$R/env"

    # Find --secrets-file PATH in argv (paired, preserves spaces in values).
    secrets_path=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--secrets-file" ]; then secrets_path="$arg"; break; fi
      prev="$arg"
    done

    if [ -n "$secrets_path" ] && [ -f "$secrets_path" ]; then
      stat -c "%a" "$secrets_path" 2>/dev/null > "$R/secrets_mode" || \
      stat -f "%OLp" "$secrets_path"           > "$R/secrets_mode"
      cp "$secrets_path" "$R/secrets_contents"
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
      tmpfs_dir:           @tmpfs_dir,
      chrome_profile_root: @chrome_profile_root,
      freentonic_cmd:      ["/bin/bash", stub_path],
      artifact_root:       @root
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
    run_dir = File.join(@runs_dir, request.run_id)

    argv = read_stub(run_dir, "argv")
    assert_includes argv, "--workflow\n"
    assert_includes argv, "--secrets\n"
    assert_includes argv, "plain_file\n"
    assert_includes argv, "--secrets-file\n"
    assert_includes argv, "--export\n"
    assert_includes argv, "http\n"
    assert_includes argv, "--export-url\n"
    assert_includes argv, "http://example.com/push\n"

    refute_includes argv, "--export-token\n",
      "token must not appear on argv (it's passed via ENV only)"
    refute_includes argv, "bearer-xyz\n",
      "token value must not appear on argv"
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

  def test_inline_secrets_written_with_mode_0600_and_content
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request
    runner.run(request)
    run_dir = File.join(@runs_dir, request.run_id)

    assert_equal "600", read_stub(run_dir, "secrets_mode").to_s.strip
    contents = read_stub(run_dir, "secrets_contents").to_s
    assert_includes contents, "USER=alice"
    assert_includes contents, "PW=s3cret"
  end

  def test_tmpfs_secrets_dir_removed_after_run
    stub = write_stub("exit 0")
    runner = build_runner(stub)
    request = build_request
    runner.run(request)

    tmpfs_run = File.join(@tmpfs_dir, request.run_id)
    refute Dir.exist?(tmpfs_run), "tmpfs run dir should be cleaned up: #{tmpfs_run}"
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
end
