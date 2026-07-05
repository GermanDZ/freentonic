# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

module Freentonic
  # Coverage for Source#extract_credentials — the require/validate/map/derive
  # logic that turns the workflow_context captured by the declarative login
  # phase into the credentials hash the Connect stage hands downstream. Pure
  # over (credentials schema + workflow_context); no Chrome needed.
  class SourceTest < Minitest::Test
    # Minimal stand-in for WorkflowSchema exposing just #credentials.
    FakeSchema = Struct.new(:credentials)

    def source_with(cred_schema)
      src = Source.new(workflow_path: "test.yml")
      schema = FakeSchema.new(cred_schema)
      src.define_singleton_method(:workflow) { schema }
      src
    end

    def extract(cred_schema, context)
      source_with(cred_schema).extract_credentials(
        nil, workflow_context: context, stdout: StringIO.new, stderr: StringIO.new
      )
    end

    def test_missing_credentials_block_is_user_error
      src = Source.new(workflow_path: "test.yml")
      src.define_singleton_method(:workflow) { FakeSchema.new(nil) }
      err = assert_raises(UserError) do
        src.extract_credentials(nil, workflow_context: {}, stdout: StringIO.new, stderr: StringIO.new)
      end
      assert_includes err.message, "credentials:"
    end

    def test_require_missing_key_is_user_error
      err = assert_raises(UserError) do
        extract({ "require" => %w[access_token] }, {})
      end
      assert_includes err.message, "did not capture access_token"
    end

    def test_require_present_passes_and_maps
      creds = extract(
        { "require" => %w[access_token], "map" => [{ "from" => "access_token", "as" => "token" }] },
        { "access_token" => "abc123" }
      )
      assert_equal({ token: "abc123" }, creds)
    end

    def test_validate_not_empty_rejects_blank
      err = assert_raises(UserError) do
        extract({ "validate" => [{ "key" => "access_token", "not_empty" => true }] },
                { "access_token" => "" })
      end
      assert_includes err.message, "is empty"
    end

    def test_validate_contains_rejects_mismatch
      err = assert_raises(UserError) do
        extract({ "validate" => [{ "key" => "cookie", "contains" => "SESSION=" }] },
                { "cookie" => "other=1" })
      end
      assert_includes err.message, "does not contain"
    end

    def test_validate_contains_accepts_match
      creds = extract(
        { "validate" => [{ "key" => "cookie", "contains" => "SESSION=" }],
          "map" => [{ "from" => "cookie", "as" => "cookie" }] },
        { "cookie" => "SESSION=xyz" }
      )
      assert_equal({ cookie: "SESSION=xyz" }, creds)
    end

    def test_map_derive_time_plus_seconds
      before = Time.now
      creds = extract(
        { "map" => [{ "from" => "expires_in", "as" => "expires_at", "derive" => "time_plus_seconds" }] },
        { "expires_in" => "3600" }
      )
      assert_kind_of Time, creds[:expires_at]
      # 3600s from now, within a generous window.
      assert_in_delta (before + 3600).to_f, creds[:expires_at].to_f, 5
    end

    def test_map_derive_time_plus_seconds_nil_when_absent
      creds = extract(
        { "map" => [{ "from" => "expires_in", "as" => "expires_at", "derive" => "time_plus_seconds" }] },
        {}
      )
      assert_nil creds[:expires_at]
    end

    def test_map_multiple_fields
      creds = extract(
        { "map" => [
          { "from" => "access_token", "as" => "token" },
          { "from" => "cookie",       "as" => "cookie" }
        ] },
        { "access_token" => "t", "cookie" => "c" }
      )
      assert_equal({ token: "t", cookie: "c" }, creds)
    end

    def test_log_extra_does_not_leak_into_result
      # log_extra is a display-only annotation; it must not change the mapped
      # value. Capture stdout to confirm the annotation is rendered there.
      out = StringIO.new
      src = source_with(
        "map" => [{ "from" => "access_token", "as" => "token",
                    "log_extra" => "user {username}" }]
      )
      creds = src.extract_credentials(
        nil,
        workflow_context: { "access_token" => "t", "username" => "alice" },
        stdout: out, stderr: StringIO.new
      )
      assert_equal({ token: "t" }, creds)
      assert_includes out.string, "user alice"
    end
  end
end
