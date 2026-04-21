# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "freentonic/invoke_request"

class InvokeRequestTest < Minitest::Test
  def setup
    @workflows_dir = Dir.mktmpdir("freentonic-test-workflows-")
    @workflow_rel = "acme/workflow.yml"
    @workflow_abs = File.join(@workflows_dir, @workflow_rel)
    FileUtils.mkdir_p(File.dirname(@workflow_abs))
    File.write(@workflow_abs, "version: 1\n")
  end

  def teardown
    FileUtils.rm_rf(@workflows_dir)
  end

  def base_body(**overrides)
    {
      "run_id"      => "run-2026-04-21-abc",
      "workflow"    => @workflow_rel,
      "credentials" => { "inline" => { "USER" => "alice", "PW" => "s3cret" } }
    }.merge(overrides.transform_keys(&:to_s))
  end

  def parse(body)
    Freentonic::InvokeRequest.from_hash(body, workflows_dir: @workflows_dir)
  end

  # ─── run_id ───

  def test_requires_run_id
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("run_id" => nil)) }
    assert_equal 400, err.status_code
  end

  def test_rejects_run_id_with_invalid_characters
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("run_id" => "bad/id")) }
    assert_equal 400, err.status_code
  end

  def test_accepts_common_run_id_charset
    req = parse(base_body.merge("run_id" => "2026-04-21T12-34-56Z.abc_123"))
    assert_equal "2026-04-21T12-34-56Z.abc_123", req.run_id
  end

  # ─── workflow resolution ───

  def test_resolves_workflow_under_root
    req = parse(base_body)
    assert_equal File.realpath(@workflow_abs), req.workflow_path
  end

  def test_rejects_path_traversal_with_dotdot
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("workflow" => "../../etc/passwd"))
    end
    assert_equal 404, err.status_code
  end

  def test_rejects_absolute_path_workflow
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("workflow" => "/etc/hostname"))
    end
    assert_equal 404, err.status_code
  end

  def test_rejects_missing_workflow
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("workflow" => "nonexistent/workflow.yml"))
    end
    assert_equal 404, err.status_code
  end

  def test_rejects_symlink_escaping_root
    outside = Tempfile.new("freentonic-outside-workflow")
    outside.write("version: 1\n"); outside.close
    link = File.join(@workflows_dir, "symlink.yml")
    File.symlink(outside.path, link)
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("workflow" => "symlink.yml"))
    end
    assert_equal 404, err.status_code
  ensure
    outside&.unlink
  end

  # ─── profile_key ───

  def test_derives_profile_key_when_missing
    req = parse(base_body)
    assert_match(/\A[0-9a-f]{16}\z/, req.profile_key)
  end

  def test_preserves_explicit_profile_key
    req = parse(base_body.merge("profile_key" => "acme__tenant42"))
    assert_equal "acme__tenant42", req.profile_key
  end

  def test_rejects_profile_key_with_slash
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("profile_key" => "bad/key")) }
    assert_equal 400, err.status_code
  end

  def test_derived_profile_key_stable_for_same_inputs
    a = parse(base_body)
    b = parse(base_body)
    assert_equal a.profile_key, b.profile_key
  end

  def test_derived_profile_key_changes_when_credentials_change
    a = parse(base_body)
    b = parse(base_body.merge("credentials" => { "inline" => { "USER" => "bob" } }))
    refute_equal a.profile_key, b.profile_key
  end

  # ─── credentials ───

  def test_rejects_credentials_missing
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("credentials" => {})) }
    assert_equal 422, err.status_code
  end

  def test_rejects_credentials_with_both_inline_and_file
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("credentials" => { "inline" => { "A" => "b" }, "file" => "/tmp/x" }))
    end
    assert_equal 422, err.status_code
  end

  def test_rejects_credentials_inline_with_newline_in_value
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("credentials" => { "inline" => { "USER" => "line1\nline2" } }))
    end
    assert_equal 422, err.status_code
  end

  def test_rejects_credentials_inline_with_invalid_key
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("credentials" => { "inline" => { "bad-key!" => "v" } }))
    end
    assert_equal 422, err.status_code
  end

  def test_credentials_file_must_exist
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("credentials" => { "file" => "/nonexistent/path.env" }))
    end
    assert_equal 422, err.status_code
  end

  # ─── export ───

  def test_export_http_requires_url
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("export" => { "mode" => "http" }))
    end
    assert_equal 400, err.status_code
  end

  def test_export_http_requires_token
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("export" => { "mode" => "http", "url" => "http://host/x" }))
    end
    assert_equal 400, err.status_code
    assert_match(/export\.token is required/, err.message)
  end

  def test_export_http_allows_empty_token_as_explicit_opt_out
    req = parse(base_body.merge("export" => { "mode" => "http", "url" => "http://host/x", "token" => "" }))
    refute req.export.key?("token"),
      "empty-string token should not propagate into the normalized export (opts out of Authorization)"
  end

  def test_export_http_accepts_token_and_headers
    req = parse(base_body.merge("export" => {
      "mode" => "http",
      "url" => "http://host/x",
      "token" => "t0ken",
      "headers" => { "X-Tenant" => "42" }
    }))
    assert_equal "t0ken", req.export["token"]
    assert_equal({ "X-Tenant" => "42" }, req.export["headers"])
  end

  def test_export_file_mode_requires_simple_path
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("export" => { "mode" => "json", "path" => "../escape.json" }))
    end
    assert_equal 400, err.status_code
  end

  def test_export_mode_enum
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("export" => { "mode" => "pdf", "path" => "out.pdf" }))
    end
    assert_equal 400, err.status_code
  end

  # ─── timeout / lookback ───

  def test_timeout_default
    assert_equal 1800, parse(base_body).timeout_sec
  end

  def test_timeout_must_be_positive
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("timeout_sec" => 0)) }
    assert_equal 400, err.status_code
  end

  def test_timeout_cap
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("timeout_sec" => 10_000)) }
    assert_equal 400, err.status_code
  end
end
