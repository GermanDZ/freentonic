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

      def test_workflow_schema_rejects_wrong_version_and_points_at_the_policy
        err = assert_raises(UserError) do
          WorkflowSchema.new(path: "/fake/providers/test.yml", raw: {
            "version"  => 2,
            "config"   => { "key" => "test" },
            "pipeline" => [],
            "phases"   => {}
          })
        end
        assert_includes err.message, "version: 1"
        assert_includes err.message, "workflow-schema-versioning"
      end

      def test_workflow_schema_rejects_await_external_approval_without_message
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "await_external_approval",
            "url_includes" => "app.revolut.com/"
          }])
        end
        assert_includes err.message, "message"
      end

      def test_workflow_schema_rejects_await_external_approval_without_url_includes
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "await_external_approval",
            "message" => "Approve on your phone"
          }])
        end
        assert_includes err.message, "url_includes"
      end

      def test_workflow_schema_rejects_await_external_approval_non_integer_timeout
        err = assert_raises(UserError) do
          schema_with_phase([{
            "action" => "await_external_approval",
            "message" => "Approve on your phone",
            "url_includes" => "app.revolut.com/",
            "timeout" => "five"
          }])
        end
        assert_includes err.message, "timeout"
      end

      def test_workflow_schema_accepts_valid_await_external_approval
        schema_with_phase([{
          "action" => "await_external_approval",
          "message" => "Approve on your phone",
          "url_includes" => "app.revolut.com/",
          "timeout" => 300
        }])
        # No exception == valid; timeout is optional (defaults in the runner).
        schema_with_phase([{
          "action" => "await_external_approval",
          "message" => "Approve on your phone",
          "url_includes" => "app.revolut.com/"
        }])
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

      # ── endpoint request headers + PUT (Ask 1) ────────────────────────

      def fake_http(captured)
        h = Object.new
        h.define_singleton_method(:use_ssl=)      { |_| }
        h.define_singleton_method(:open_timeout=) { |_| }
        h.define_singleton_method(:read_timeout=) { |_| }
        h.define_singleton_method(:request) do |req|
          captured[:method]  = req.method
          captured[:body]    = req.body
          captured[:headers] = req.each_header.to_h
          Struct.new(:code, :body) do
            def [](k) = k.to_s.casecmp("content-type").zero? ? "application/json" : nil
          end.new("200", '{"ok":true}')
        end
        h
      end

      def test_get_endpoint_headers_from_yaml_are_sent
        schema = schema_with(
          "base_url"  => "https://ing.ingdirect.es",
          "endpoints" => [{
            "name"    => "sca_challenge",
            "method"  => "GET",
            "path"    => "/genoma_api/rest/sca/documentation",
            "headers" => { "x-ing-reset-validations" => "1" }
          }]
        )
        client = schema.build_api_client({})
        captured = {}
        with_net_http_new(fake_http(captured)) { client.sca_challenge }
        assert_equal "GET", captured[:method]
        assert_equal "1",   captured[:headers]["x-ing-reset-validations"]
      end

      def test_put_endpoint_with_templated_header_from_yaml
        schema = schema_with(
          "base_url"  => "https://ing.ingdirect.es",
          "endpoints" => [{
            "name"    => "sca_commit",
            "method"  => "PUT",
            "path"    => "/genoma_api/rest/sca/documentation",
            "json"    => { "processId" => "{process_id}" },
            "headers" => { "x-ing-securityprocessid" => "{process_id}" }
          }]
        )
        client = schema.build_api_client({})
        captured = {}
        with_net_http_new(fake_http(captured)) { client.sca_commit(process_id: "p-9") }
        assert_equal "PUT", captured[:method]
        assert_equal "p-9", captured[:headers]["x-ing-securityprocessid"]
        assert_equal({ "processId" => "p-9" }, ::JSON.parse(captured[:body]))
      end

      def test_endpoint_with_unsupported_method_is_rejected
        schema = schema_with(
          "base_url"  => "https://example.com",
          "endpoints" => [{ "name" => "wat", "method" => "DELETE", "path" => "/x" }]
        )
        err = assert_raises(UserError) { schema.build_api_client({}) }
        assert_includes err.message, "unsupported"
        assert_includes err.message, "DELETE"
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

      # ── capture_local_storage / capture_session_storage ───────────────

      def valid_capture_local_storage(extra = {})
        {
          "action" => "capture_local_storage",
          "origin" => "https://ing.example",
          "as"     => "ls"
        }.merge(extra)
      end

      def test_capture_local_storage_accepts_minimal_step
        schema_with_phase([valid_capture_local_storage])
      end

      def test_capture_local_storage_accepts_keys_allowlist
        schema_with_phase([valid_capture_local_storage("keys" => ["a", "b"])])
      end

      def test_capture_local_storage_rejects_missing_origin
        err = assert_raises(UserError) do
          step = valid_capture_local_storage; step.delete("origin")
          schema_with_phase([step])
        end
        assert_includes err.message, "origin"
      end

      def test_capture_local_storage_rejects_missing_as
        err = assert_raises(UserError) do
          step = valid_capture_local_storage; step.delete("as")
          schema_with_phase([step])
        end
        assert_includes err.message, "as"
      end

      def test_capture_local_storage_rejects_non_array_keys
        err = assert_raises(UserError) do
          schema_with_phase([valid_capture_local_storage("keys" => "ExtendedSessionContext")])
        end
        assert_includes err.message, "keys"
      end

      def test_capture_local_storage_rejects_empty_keys_array
        err = assert_raises(UserError) do
          schema_with_phase([valid_capture_local_storage("keys" => [])])
        end
        assert_includes err.message, "keys"
      end

      def test_capture_local_storage_rejects_non_string_keys_entry
        err = assert_raises(UserError) do
          schema_with_phase([valid_capture_local_storage("keys" => ["ok", 123])])
        end
        assert_includes err.message, "keys"
      end

      def test_capture_session_storage_uses_same_validator
        # capture_session_storage must follow the same validator path —
        # otherwise providers could ship invalid YAML for one variant but
        # not the other.
        err = assert_raises(UserError) do
          schema_with_phase([{ "action" => "capture_session_storage", "as" => "ss" }])
        end
        assert_includes err.message, "origin"
      end

      # ── capture_outbound_request_headers ───────────────────────────────

      def valid_capture_outbound(extra = {})
        {
          "action"  => "capture_outbound_request_headers",
          "host"    => "api.ing.example",
          "path"    => "/v2/products/",
          "headers" => ["Authorization", "X-XSRF-TOKEN"],
          "as"      => "ing_api_headers"
        }.merge(extra)
      end

      def test_capture_outbound_accepts_valid_step
        schema_with_phase([valid_capture_outbound])
      end

      %w[host path as].each do |key|
        define_method("test_capture_outbound_rejects_missing_#{key}") do
          step = valid_capture_outbound; step.delete(key)
          err = assert_raises(UserError) { schema_with_phase([step]) }
          assert_includes err.message, key
        end
      end

      def test_capture_outbound_rejects_missing_headers
        step = valid_capture_outbound; step.delete("headers")
        err = assert_raises(UserError) { schema_with_phase([step]) }
        assert_includes err.message, "headers"
      end

      def test_capture_outbound_rejects_empty_headers_array
        err = assert_raises(UserError) { schema_with_phase([valid_capture_outbound("headers" => [])]) }
        assert_includes err.message, "headers"
      end

      def test_capture_outbound_rejects_non_string_headers_entry
        err = assert_raises(UserError) { schema_with_phase([valid_capture_outbound("headers" => ["ok", 7])]) }
        assert_includes err.message, "headers"
      end

      def test_capture_outbound_rejects_non_boolean_most_recent
        err = assert_raises(UserError) { schema_with_phase([valid_capture_outbound("most_recent" => "yes")]) }
        assert_includes err.message, "most_recent"
      end

      # ── auth_headers Array (per-host) form ─────────────────────────────

      def per_host_schema
        schema_with(
          "base_url"     => "https://legacy.example.com",
          "credentials"  => ["cookie", "bearer"],
          "auth_headers" => [
            { "headers" => { "Cookie" => "{cookie}" } },
            { "host"    => "api.example.com",
              "headers" => { "Authorization" => "{bearer}" } }
          ]
        )
      end

      def test_auth_headers_array_form_unscoped_block_applies_everywhere
        client = per_host_schema.build_api_client({ cookie: "c=1", bearer: "Bearer abc" })
        h = client.send(:auth_headers_for, "https://legacy.example.com/x")
        assert_equal "c=1", h["Cookie"]
        refute h.key?("Authorization")
      end

      def test_auth_headers_array_form_scoped_block_applies_only_on_match
        client = per_host_schema.build_api_client({ cookie: "c=1", bearer: "Bearer abc" })
        h = client.send(:auth_headers_for, "https://api.example.com/v2")
        assert_equal "c=1",        h["Cookie"]
        assert_equal "Bearer abc", h["Authorization"]
      end

      def test_auth_headers_array_form_supports_static_values
        schema = schema_with(
          "auth_headers" => [{ "host" => "api.example.com",
                               "headers" => { "X-Static" => "lit" } }]
        )
        client = schema.build_api_client({})
        assert_equal "lit", client.send(:auth_headers_for, "https://api.example.com/x")["X-Static"]
        refute client.send(:auth_headers_for, "https://other.example.com/x").key?("X-Static")
      end

      def test_auth_headers_hash_form_still_works
        schema = schema_with(
          "credentials"  => ["token"],
          "auth_headers" => { "Authorization" => "{token}", "X-Static" => "lit" }
        )
        client = schema.build_api_client({ token: "tok" })
        h = client.send(:auth_headers_for, "https://anything.example.com/x")
        assert_equal "tok", h["Authorization"]
        assert_equal "lit", h["X-Static"]
      end

      def test_auth_headers_array_rejects_block_without_headers
        schema = schema_with("auth_headers" => [{ "host" => "api.example.com" }])
        err = assert_raises(UserError) { schema.build_api_client({}) }
        assert_includes err.message, "headers"
      end

      def test_auth_headers_array_rejects_empty_headers_hash
        schema = schema_with("auth_headers" => [{ "host" => "api.example.com", "headers" => {} }])
        err = assert_raises(UserError) { schema.build_api_client({}) }
        assert_includes err.message, "headers"
      end

      def test_auth_headers_array_rejects_non_hash_block
        schema = schema_with("auth_headers" => ["just a string"])
        err = assert_raises(UserError) { schema.build_api_client({}) }
        assert_includes err.message, "auth_headers"
      end

      def test_auth_headers_array_rejects_empty_host
        schema = schema_with("auth_headers" => [{ "host" => "", "headers" => { "X" => "y" } }])
        err = assert_raises(UserError) { schema.build_api_client({}) }
        assert_includes err.message, "host"
      end

      def test_auth_headers_rejects_non_hash_non_array
        schema = schema_with("auth_headers" => "Cookie: c")
        err = assert_raises(UserError) { schema.build_api_client({}) }
        assert_includes err.message, "auth_headers"
      end

      # ── derived_credentials key: (Hash pluck) form ─────────────────────

      def test_derived_credentials_key_form_plucks_from_hash
        schema = schema_with(
          "credentials" => ["headers_bag"],
          "derived_credentials" => {
            "auth_token" => { "from" => "headers_bag", "key" => "Authorization" }
          }
        )
        client = schema.build_api_client({ headers_bag: { "Authorization" => "Bearer abc" } })
        assert_equal "Bearer abc", client.send(:auth_token)
      end

      def test_derived_credentials_key_form_missing_key_returns_nil
        schema = schema_with(
          "credentials" => ["bag"],
          "derived_credentials" => {
            "auth_token" => { "from" => "bag", "key" => "Authorization" }
          }
        )
        client = schema.build_api_client({ bag: { "Other" => "x" } })
        assert_nil client.send(:auth_token)
      end

      def test_derived_credentials_regex_form_still_works
        schema = schema_with(
          "credentials" => ["cookie"],
          "derived_credentials" => {
            "session_id" => { "from" => "cookie", "regex" => "session-id=([^;]+)", "capture" => 1 }
          }
        )
        client = schema.build_api_client({ cookie: "session-id=abc; other=1" })
        assert_equal "abc", client.send(:session_id)
      end

      def test_derived_credentials_rejects_both_regex_and_key
        schema = schema_with(
          "derived_credentials" => {
            "x" => { "from" => "y", "regex" => "(.+)", "key" => "k" }
          }
        )
        err = assert_raises(UserError) { schema.build_api_client({}) }
        assert_includes err.message, '"x"'
        assert_includes err.message, "regex"
        assert_includes err.message, "key"
      end

      def test_derived_credentials_rejects_neither_regex_nor_key
        schema = schema_with(
          "derived_credentials" => {
            "x" => { "from" => "y" }
          }
        )
        err = assert_raises(UserError) { schema.build_api_client({}) }
        assert_includes err.message, '"x"'
        assert_includes err.message, "must declare"
      end
    end
  end
