require_relative "test_helper"

module Freentonic
    class WorkflowSchemaClientTest < Minitest::Test
      def schema_with(api_client_config)
        WorkflowSchema.new(path: "/fake/providers/test.yml", raw: {
          "version"  => 1,
          "config"   => { "key" => "test", "default_lookback_days" => 30 },
          "pipeline" => [],
          "phases"   => {},
          "api_client" => api_client_config
        })
      end

      def schema_with_phase(steps)
        WorkflowSchema.new(path: "/fake/providers/test.yml", raw: {
          "version"  => 1,
          "config"   => { "key" => "test", "default_lookback_days" => 30 },
          "pipeline" => ["login"],
          "phases"   => { "login" => steps }
        })
      end

      def test_workflow_schema_rejects_prompt_stdin_and_fill_without_timeout
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "prompt_stdin_and_fill",
            "selector" => "input[name='otp']",
            "prompt" => "Enter code: "
          }])
        end
        assert_includes err.message, "timeout"
      end

      def test_workflow_schema_rejects_prompt_stdin_and_fill_with_non_integer_timeout
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "prompt_stdin_and_fill",
            "selector" => "input[name='otp']",
            "prompt" => "Enter code: ",
            "timeout" => "five"
          }])
        end
        assert_includes err.message, "timeout"
      end

      def test_workflow_schema_rejects_when_context_unknown_operator
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "navigate",
            "url" => "https://x",
            "when_context" => { "lookback_days" => { "between" => 30 } }
          }])
        end
        assert_includes err.message, "unknown operator"
      end

      def test_workflow_schema_rejects_when_context_non_numeric_operand_for_gt
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "navigate",
            "url" => "https://x",
            "when_context" => { "lookback_days" => { "gt" => "thirty" } }
          }])
        end
        assert_includes err.message, "numeric"
      end

      def test_workflow_schema_rejects_when_context_non_boolean_operand_for_present
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "navigate",
            "url" => "https://x",
            "when_context" => { "device_id" => { "present" => "yes" } }
          }])
        end
        assert_includes err.message, "boolean"
      end

      def test_workflow_schema_rejects_when_context_not_a_hash
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "navigate",
            "url" => "https://x",
            "when_context" => "lookback_days > 30"
          }])
        end
        assert_includes err.message, "when_context"
      end

      def test_workflow_schema_accepts_valid_when_context
        schema_with_phase([{
          "action" => "navigate",
          "url" => "https://x",
          "when_context" => {
            "lookback_days" => { "gt" => 30, "lte" => 3650 },
            "isolated" => { "eq" => false },
            "device_id" => { "present" => true }
          }
        }])
      end

      def test_workflow_schema_rejects_click_text_without_text
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "click_text" }])
        end
        assert_includes err.message, "text"
      end

      def test_workflow_schema_rejects_click_text_empty_text
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "click_text", "text" => "" }])
        end
        assert_includes err.message, "text"
      end

      def test_workflow_schema_rejects_click_text_unknown_role
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "click_text", "text" => "Go", "role" => "combobox" }])
        end
        assert_includes err.message, "role"
      end

      def test_workflow_schema_rejects_click_text_unknown_match
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "click_text", "text" => "Go", "match" => "regex" }])
        end
        assert_includes err.message, "match"
      end

      def test_workflow_schema_accepts_valid_click_text
        schema_with_phase([{
          "action" => "click_text",
          "text" => "Buscar",
          "role" => "button",
          "within" => "#modal",
          "match" => "contains",
          "timeout" => 10
        }])
      end

      def test_workflow_schema_rejects_fill_clear_non_boolean
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "fill",
            "selector" => "#x",
            "value" => "y",
            "clear" => "yes"
          }])
        end
        assert_includes err.message, "clear"
      end

      def test_workflow_schema_accepts_fill_clear_true_false_and_omitted
        schema_with_phase([{ "action" => "fill", "selector" => "#x", "value" => "y", "clear" => true }])
        schema_with_phase([{ "action" => "fill", "selector" => "#x", "value" => "y", "clear" => false }])
        schema_with_phase([{ "action" => "fill", "selector" => "#x", "value" => "y" }])
        schema_with_phase([{ "action" => "fill_if_present", "selector" => "#x", "value" => "y", "clear" => true }])
      end

      def test_workflow_schema_accepts_valid_prompt_stdin_and_fill
        schema_with_phase([{
          "action" => "prompt_stdin_and_fill",
          "selector" => "input[name='otp']",
          "prompt" => "Enter code: ",
          "timeout" => 300,
          "submit_selector" => "button.go",
          "if_present" => true
        }])
      end

      # ─── record_requests schema validation ───

      def test_workflow_schema_rejects_record_requests_without_url_matches
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "record_requests" }])
        end
        assert_includes err.message, "url_matches"
      end

      def test_workflow_schema_rejects_record_requests_empty_url_matches
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "record_requests", "url_matches" => [] }])
        end
        assert_includes err.message, "url_matches"
      end

      def test_workflow_schema_rejects_record_requests_non_string_url_matches
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "record_requests", "url_matches" => [123] }])
        end
        assert_includes err.message, "url_matches"
      end

      def test_workflow_schema_rejects_record_requests_over_entry_cap
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "record_requests",
            "url_matches" => ["example.com/api/"],
            "max_entries" => 999_999
          }])
        end
        assert_includes err.message, "max_entries"
      end

      def test_workflow_schema_rejects_record_requests_over_body_cap
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "record_requests",
            "url_matches" => ["example.com/api/"],
            "max_body_bytes" => 999_999_999
          }])
        end
        assert_includes err.message, "max_body_bytes"
      end

      def test_workflow_schema_rejects_record_requests_non_boolean_include_body
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "record_requests",
            "url_matches" => ["example.com/api/"],
            "include_response_body" => "yes"
          }])
        end
        assert_includes err.message, "include_response_body"
      end

      def test_workflow_schema_accepts_valid_record_requests
        schema_with_phase([{
          "action" => "record_requests",
          "url_matches" => ["example.com/api/"],
          "include_response_body" => true,
          "max_body_bytes" => 131072,
          "max_entries" => 500
        }])
      end

      # ─── dump_requests schema validation ───

      def test_workflow_schema_rejects_dump_requests_without_path
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "dump_requests" }])
        end
        assert_includes err.message, "path"
      end

      def test_workflow_schema_rejects_dump_requests_empty_path
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "dump_requests", "path" => "" }])
        end
        assert_includes err.message, "path"
      end

      def test_workflow_schema_rejects_dump_requests_unknown_format
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "dump_requests", "path" => "/tmp/x.json", "format" => "xml" }])
        end
        assert_includes err.message, "format"
      end

      def test_workflow_schema_rejects_dump_requests_non_boolean_reset
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "dump_requests", "path" => "/tmp/x.json", "reset" => "yes" }])
        end
        assert_includes err.message, "reset"
      end

      def test_workflow_schema_accepts_valid_dump_requests
        schema_with_phase([{
          "action" => "dump_requests",
          "path" => "/tmp/capture.json",
          "format" => "har",
          "reset" => true
        }])
      end

      # ─── pause schema validation ───

      def test_workflow_schema_rejects_pause_without_message
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "pause", "timeout" => 60 }])
        end
        assert_includes err.message, "message"
      end

      def test_workflow_schema_rejects_pause_without_timeout
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "pause", "message" => "Wait here." }])
        end
        assert_includes err.message, "timeout"
      end

      def test_workflow_schema_accepts_valid_pause
        schema_with_phase([{
          "action" => "pause",
          "message" => "Do something manually.",
          "timeout" => 600
        }])
      end

      # ─── capture_url schema validation ───

      def test_workflow_schema_rejects_capture_url_without_as
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "capture_url" }])
        end
        assert_includes err.message, "as"
      end

      def test_workflow_schema_rejects_capture_url_empty_as
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "capture_url", "as" => "" }])
        end
        assert_includes err.message, "as"
      end

      def test_workflow_schema_accepts_valid_capture_url
        schema_with_phase([{
          "action" => "capture_url",
          "as" => "current_page"
        }])
      end

      def test_builds_client_with_credentials
        schema = schema_with("credentials" => ["token"])
        client = schema.build_api_client({ token: "tok-123" })
        assert_equal "tok-123", client.send(:token)
      end

      def test_builds_client_with_required_credentials
        schema = schema_with(
          "credentials" => { "keys" => ["token", "secret"], "required" => true }
        )
        assert_raises(ArgumentError) { schema.build_api_client({ token: nil, secret: "s" }) }
        client = schema.build_api_client({ token: "t", secret: "s" })
        assert_equal "t", client.send(:token)
      end

      def test_static_auth_header
        schema = schema_with("auth_headers" => { "X-Static" => "value" })
        client = schema.build_api_client({})
        assert_equal "value", client.send(:auth_headers)["X-Static"]
      end

      def test_dynamic_auth_header
        schema = schema_with(
          "credentials"  => ["token"],
          "auth_headers" => { "Authorization" => "{token}" }
        )
        client = schema.build_api_client({ token: "my-tok" })
        assert_equal "my-tok", client.send(:auth_headers)["Authorization"]
      end

      def test_batch_keys
        schema = schema_with("batch_keys" => ["items", "results"])
        client = schema.build_api_client({})
        assert_equal [1, 2], client.send(:extract_batch, { "items" => [1, 2] })
        assert_equal [3],    client.send(:extract_batch, { "results" => [3] })
        assert_equal [],     client.send(:extract_batch, { "other" => [4] })
      end

      def test_date_format
        schema = schema_with("date_format" => "%d/%m/%Y")
        client = schema.build_api_client({})
        assert_equal "15/03/2024", client.send(:format_date, Date.new(2024, 3, 15))
        assert_equal "15/03/2024", client.send(:format_date, "2024-03-15")
      end

      def test_yaml_value
        schema = schema_with("base_url" => "https://example.com", "custom_key" => "hello")
        client = schema.build_api_client({})
        assert_equal "https://example.com", client.send(:yaml_value, "base_url")
        assert_equal "hello",               client.send(:yaml_value, "custom_key")
      end

      def test_class_is_memoized
        schema = schema_with("credentials" => ["token"])
        klass1 = schema.build_api_client({ token: "a" }).class
        klass2 = schema.build_api_client({ token: "b" }).class
        assert_same klass1, klass2
      end

      def test_returns_nil_when_no_api_client_section
        schema = WorkflowSchema.new(path: "/fake/test.yml", raw: {
          "version"  => 1,
          "config"   => { "key" => "test", "default_lookback_days" => 30 },
          "pipeline" => [],
          "phases"   => {}
        })
        assert_nil schema.build_api_client({})
      end

      # ── capture_response_header ───────────────────────────────────────

      def valid_capture_response_header(extra = {})
        {
          "action" => "capture_response_header",
          "host"   => "api.example.com",
          "path"   => "/auth/token",
          "header" => "Authorization",
          "as"     => "bearer_token"
        }.merge(extra)
      end

      def test_capture_response_header_accepts_full_step
        # Sanity: a valid step should not raise.
        schema_with_phase([valid_capture_response_header])
      end

      def test_capture_response_header_accepts_required_false
        schema_with_phase([valid_capture_response_header("required" => false)])
      end

      %w[host path header as].each do |required_key|
        define_method("test_capture_response_header_rejects_missing_#{required_key}") do
          step = valid_capture_response_header
          step.delete(required_key)
          err = assert_raises(UserError) { schema_with_phase([step]) }
          assert_includes err.message, required_key
        end

        define_method("test_capture_response_header_rejects_empty_#{required_key}") do
          err = assert_raises(UserError) { schema_with_phase([valid_capture_response_header(required_key => "")]) }
          assert_includes err.message, required_key
        end

        define_method("test_capture_response_header_rejects_non_string_#{required_key}") do
          err = assert_raises(UserError) { schema_with_phase([valid_capture_response_header(required_key => 123)]) }
          assert_includes err.message, required_key
        end
      end

      def test_capture_response_header_rejects_non_boolean_required
        err = assert_raises(UserError) do
          schema_with_phase([valid_capture_response_header("required" => "yes")])
        end
        assert_includes err.message, "required"
      end
    end
  end
