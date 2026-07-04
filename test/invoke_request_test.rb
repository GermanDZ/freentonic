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

  def test_rejects_dot_run_id
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("run_id" => ".")) }
    assert_equal 400, err.status_code
  end

  def test_rejects_dotdot_run_id
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("run_id" => "..")) }
    assert_equal 400, err.status_code
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

  def test_rejects_dot_profile_key
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("profile_key" => ".")) }
    assert_equal 400, err.status_code
  end

  def test_rejects_dotdot_profile_key
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("profile_key" => "..")) }
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

  def test_credentials_file_resolves_under_secrets_root
    Dir.mktmpdir("freentonic-test-secrets-") do |secrets_dir|
      creds = File.join(secrets_dir, "acme.env")
      File.write(creds, "USER=alice\n")
      req = Freentonic::InvokeRequest.from_hash(
        base_body.merge("credentials" => { "file" => "acme.env" }),
        workflows_dir: @workflows_dir, secrets_dir: secrets_dir
      )
      assert_equal File.realpath(creds), req.credentials_file
    end
  end

  def test_credentials_file_absolute_path_is_rerooted_and_cannot_escape
    Dir.mktmpdir("freentonic-test-secrets-") do |secrets_dir|
      # An absolute path is interpreted relative to the secrets root, so it
      # can't reach a real /etc file — it maps to <root>/etc/passwd, absent.
      err = assert_raises(Freentonic::InvokeError) do
        Freentonic::InvokeRequest.from_hash(
          base_body.merge("credentials" => { "file" => "/etc/passwd" }),
          workflows_dir: @workflows_dir, secrets_dir: secrets_dir
        )
      end
      assert_equal 422, err.status_code
    end
  end

  def test_credentials_file_symlink_escaping_root_is_rejected
    Dir.mktmpdir("freentonic-test-secrets-") do |secrets_dir|
      outside = Tempfile.new("freentonic-outside-creds")
      outside.write("USER=alice\n"); outside.flush
      link = File.join(secrets_dir, "escape.env")
      File.symlink(outside.path, link)
      err = assert_raises(Freentonic::InvokeError) do
        Freentonic::InvokeRequest.from_hash(
          base_body.merge("credentials" => { "file" => "escape.env" }),
          workflows_dir: @workflows_dir, secrets_dir: secrets_dir
        )
      end
      assert_equal 422, err.status_code
    ensure
      outside&.close!
    end
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

  # ─── vnc_password ───

  def test_vnc_password_missing_is_nil
    req = parse(base_body)
    assert_nil req.vnc_password
  end

  def test_vnc_password_valid_printable_ascii_accepted
    req = parse(base_body.merge("vnc_password" => "MyPass-2026!"))
    assert_equal "MyPass-2026!", req.vnc_password
  end

  def test_vnc_password_rejects_whitespace
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("vnc_password" => "has space"))
    end
    assert_equal 400, err.status_code
  end

  def test_vnc_password_rejects_control_char
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("vnc_password" => "ctrl\x01char"))
    end
    assert_equal 400, err.status_code
  end

  def test_vnc_password_rejects_newline
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("vnc_password" => "two\nlines"))
    end
    assert_equal 400, err.status_code
  end

  def test_vnc_password_length_cap
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("vnc_password" => "x" * 65))
    end
    assert_equal 400, err.status_code
  end

  def test_vnc_password_rejects_non_string
    err = assert_raises(Freentonic::InvokeError) do
      parse(base_body.merge("vnc_password" => 12345))
    end
    assert_equal 400, err.status_code
  end

  # ─── interactive (browse mode) ───

  def test_interactive_defaults_to_false
    req = parse(base_body)
    assert_equal false, req.interactive
  end

  def test_interactive_accepts_true
    req = parse(base_body.merge("interactive" => true))
    assert_equal true, req.interactive
  end

  def test_interactive_accepts_explicit_false
    req = parse(base_body.merge("interactive" => false))
    assert_equal false, req.interactive
  end

  def test_interactive_rejects_non_boolean
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("interactive" => "true")) }
    assert_equal 400, err.status_code
  end

  def test_interactive_rejects_truthy_int
    err = assert_raises(Freentonic::InvokeError) { parse(base_body.merge("interactive" => 1)) }
    assert_equal 400, err.status_code
  end

  # Interactive mode short-circuits the engine before Export ever
  # runs, so a malformed `export` block must not block the request.
  # (Clients like simplefreen always ship the same export config and
  # only flip the interactive flag.)
  def test_interactive_skips_export_validation_entirely
    req = parse(base_body.merge(
      "interactive" => true,
      "export" => { "mode" => "http" } # missing url+token; would normally raise
    ))
    assert_nil req.export
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
