require_relative "test_helper"
require "stringio"

module Freentonic
    class BrowserWorkflowRunnerTest < Minitest::Test
      def test_sanitize_screenshot_label_blocks_traversal
        # Path separators and any non-[A-Za-z0-9_.-] char become underscores.
        # `.` on its own is allowed (so "foo.bar" works), but it can't combine
        # with `/` to escape — the `/` itself always becomes `_`.
        assert_equal "_..escape",
          BrowserWorkflowRunner.sanitize_screenshot_label("/..escape")
        assert_equal "foo_bar",
          BrowserWorkflowRunner.sanitize_screenshot_label("foo/bar")
        # URL-encoded traversal is also neutralized — the `%` becomes `_`.
        assert_equal ".._2F_escape",
          BrowserWorkflowRunner.sanitize_screenshot_label("..%2F/escape")
      end

      def test_sanitize_screenshot_label_preserves_safe_chars
        assert_equal "login-step_3.png",
          BrowserWorkflowRunner.sanitize_screenshot_label("login-step_3.png")
      end

      def test_sanitize_screenshot_label_replaces_empty
        assert_equal "unlabelled", BrowserWorkflowRunner.sanitize_screenshot_label("")
        assert_equal "unlabelled", BrowserWorkflowRunner.sanitize_screenshot_label(nil)
      end

      def test_sanitize_screenshot_label_caps_length
        long = "a" * 200
        result = BrowserWorkflowRunner.sanitize_screenshot_label(long)
        assert_operator result.bytesize, :<=, 64
      end

      class FakeSession
        attr_reader :commands

        def initialize
          @commands = []
          @pending_events = []
        end

        def send_command(method, params = {}, timeout: 30)
          @commands << { method: method, params: params, timeout: timeout }

          if method == "Runtime.evaluate"
            { "result" => { "value" => true } }
          else
            {}
          end
        end

        attr_reader :pending_events
      end

      class SourceDouble
        def key
          "ing"
        end
      end

      class SchemaDouble
        def error_signals = []

        def phase(name)
          return [] unless name == "login"

          [
            {
              "action" => "fill",
              "selector" => "#dni",
              "value" => "secret(USER_DNI)"
            },
            {
              "action" => "enter_digits",
              "keypad" => "#pin_pad",
              "digits" => [
                "secret(PIN_DIGIT_1)",
                "secret(PIN_DIGIT_2)",
                "secret(PIN_DIGIT_3)"
              ]
            }
          ]
        end

        def secret_config(name)
          { "prompt" => "Prompt for #{name}" }
        end
      end

      class CaptureSchemaDouble
        def error_signals = []

        def phase(name)
          return [] unless name == "capture_credentials"

          [
            {
              "action" => "capture_header",
              "name" => "tokencsrf",
              "as" => "tokencsrf"
            },
            {
              "action" => "capture_cookie_header",
              "host" => "bank.example",
              "path" => "/services/rest/",
              "as" => "cookie"
            }
          ]
        end

        def secret_config(_name)
          {}
        end
      end

      class FakeSecretResolver
        attr_reader :calls

        def initialize
          @calls = []
        end

        def resolve_value(source:, schema:, value:)
          @calls << value
          case value
          when "secret(USER_DNI)" then "12345678A"
          when "secret(PIN_DIGIT_1)" then "1"
          when "secret(PIN_DIGIT_2)" then "3"
          when "secret(PIN_DIGIT_3)" then "5"
          when Array
            value.map { |item| resolve_value(source: source, schema: schema, value: item) }
          else
            value
          end
        end
      end

      def test_login_phase_can_use_secret_references
        session = FakeSession.new
        resolver = FakeSecretResolver.new
        stdout = StringIO.new
        context = {}

        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: SchemaDouble.new,
          context: context,
          secret_resolver: resolver,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: stdout,
          stderr: StringIO.new
        ).execute_phase("login")

        runtime_calls  = session.commands.select { |command| command[:method] == "Runtime.evaluate" }
        keystroke_calls = session.commands.select { |command| command[:method] == "Input.dispatchKeyEvent" }

        # fill dispatches one Runtime.evaluate (deepQuery to focus element) then
        # types the resolved value character-by-character via Input.dispatchKeyEvent.
        assert_equal 4, runtime_calls.size
        assert_includes runtime_calls.first[:params][:expression], "#dni"

        typed_chars = keystroke_calls.select { |c| c[:params][:type] == "char" }.map { |c| c[:params][:text] }
        assert_equal "12345678A".chars, typed_chars.first("12345678A".length)

        assert_includes runtime_calls[1][:params][:expression], "\"1\""
        assert_includes runtime_calls[2][:params][:expression], "\"3\""
        assert_includes runtime_calls[3][:params][:expression], "\"5\""
        assert_includes stdout.string, "Running login phase..."
      end

      def test_capture_phase_collects_headers_and_cookie_headers
        session = FakeSession.new
        session.pending_events << {
          "method" => "Network.requestWillBeSent",
          "params" => {
            "request" => {
              "headers" => { "tokencsrf" => "csrf-123" }
            }
          }
        }
        context = {}

        cookies = [
          { "name" => "sid", "value" => "abc", "domain" => ".bank.example", "path" => "/services/rest/" }
        ]

        original_get_all_cookies = Freentonic::ChromeCdp.method(:get_all_cookies)
        Freentonic::ChromeCdp.define_singleton_method(:get_all_cookies) { |_session| cookies }
        begin
          BrowserWorkflowRunner.new(
            source: SourceDouble.new,
            session: session,
            schema: CaptureSchemaDouble.new,
            context: context,
            secret_resolver: FakeSecretResolver.new,
            session_drainer: ->(_session, iterations:, sleep_seconds:) {},
            stdout: StringIO.new,
            stderr: StringIO.new
          ).execute_phase("capture_credentials")
        ensure
          Freentonic::ChromeCdp.define_singleton_method(:get_all_cookies, original_get_all_cookies)
        end

        assert_equal "csrf-123", context["tokencsrf"]
        assert_equal "sid=abc", context["cookie"]
        assert_equal 1, context["cookie_cookie_count"]
      end

      class CaptureResponseHeaderSchemaDouble
        def initialize(steps); @steps = steps; end
        def error_signals = []
        def phase(name); name == "capture_credentials" ? @steps : []; end
        def secret_config(_name); {}; end
      end

      def test_capture_response_header_lifts_value_from_matching_response
        session = FakeSession.new
        session.pending_events << {
          "method" => "Network.responseReceived",
          "params" => {
            "requestId" => "req-9",
            "response" => {
              "url" => "https://api.ing.ingdirect.es/saf/tpa/accesstoken/synchronize",
              "headers" => { "Authorization" => "Bearer post-elevation-token" }
            }
          }
        }
        steps = [{
          "action" => "capture_response_header",
          "host"   => "api.ing.ingdirect.es",
          "path"   => "/saf/tpa/accesstoken/synchronize",
          "header" => "Authorization",
          "as"     => "bearer_token"
        }]
        context = {}
        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: CaptureResponseHeaderSchemaDouble.new(steps),
          context: context,
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: StringIO.new,
          stderr: StringIO.new
        ).execute_phase("capture_credentials")

        assert_equal "Bearer post-elevation-token", context["bearer_token"]
      end

      def test_capture_response_header_required_false_does_not_raise_on_miss
        session = FakeSession.new
        # No matching response event in pending_events.
        steps = [{
          "action" => "capture_response_header",
          "host"   => "api.ing.ingdirect.es",
          "path"   => "/saf/tpa/accesstoken/synchronize",
          "header" => "Authorization",
          "as"     => "bearer_token",
          "required" => false
        }]
        context = {}
        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: CaptureResponseHeaderSchemaDouble.new(steps),
          context: context,
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: StringIO.new,
          stderr: StringIO.new
        ).execute_phase("capture_credentials")

        refute context.key?("bearer_token")
      end

      def test_capture_response_header_required_true_raises_on_miss
        session = FakeSession.new
        steps = [{
          "action" => "capture_response_header",
          "host"   => "api.ing.ingdirect.es",
          "path"   => "/saf/tpa/accesstoken/synchronize",
          "header" => "Authorization",
          "as"     => "bearer_token"
        }]
        runner = BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: CaptureResponseHeaderSchemaDouble.new(steps),
          context: {},
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: StringIO.new,
          stderr: StringIO.new
        )
        assert_raises(UserError) { runner.execute_phase("capture_credentials") }
      end

      def test_capture_response_header_does_not_log_value_to_stdout
        session = FakeSession.new
        session.pending_events << {
          "method" => "Network.responseReceived",
          "params" => {
            "requestId" => "req-1",
            "response" => {
              "url" => "https://api.ing.ingdirect.es/x",
              "headers" => { "Authorization" => "Bearer ABSOLUTELYSECRET" }
            }
          }
        }
        steps = [{
          "action" => "capture_response_header",
          "host" => "api.ing.ingdirect.es", "path" => "/x",
          "header" => "Authorization", "as" => "bearer_token"
        }]
        stdout = StringIO.new
        stderr = StringIO.new
        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: CaptureResponseHeaderSchemaDouble.new(steps),
          context: {},
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: stdout,
          stderr: stderr
        ).execute_phase("capture_credentials")

        refute_includes stdout.string, "ABSOLUTELYSECRET"
        refute_includes stderr.string, "ABSOLUTELYSECRET"
      end

      class ResponseJsonSchemaDouble
        def error_signals = []

        def phase(name)
          return [] unless name == "capture_credentials"

          [
            {
              "action" => "capture_response_json",
              "url_includes" => "/oauth2/token",
              "exclude_url" => "/revoke",
              "field" => "access_token",
              "as" => "access_token",
              "required" => false
            }
          ]
        end

        def secret_config(_name)
          {}
        end
      end

      def test_capture_response_json_extracts_field_from_response_body
        session = FakeSession.new
        session.pending_events << {
          "method" => "Network.responseReceived",
          "params" => {
            "requestId" => "req-1",
            "response" => { "url" => "https://bank.example/oauth2/token" }
          }
        }
        context = {}

        original_send = session.method(:send_command)
        session.define_singleton_method(:send_command) do |method, params = {}, timeout: 30|
          if method == "Network.getResponseBody" && params[:requestId] == "req-1"
            { "body" => '{"access_token":"tok-abc","expires_in":300}' }
          else
            original_send.call(method, params, timeout: timeout)
          end
        end

        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: ResponseJsonSchemaDouble.new,
          context: context,
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: StringIO.new,
          stderr: StringIO.new
        ).execute_phase("capture_credentials")

        assert_equal "tok-abc", context["access_token"]
      end

      class PromptSchemaDouble
        def initialize(steps)
          @steps = steps
        end

        def error_signals = []

        def phase(name)
          name == "login" ? @steps : []
        end

        def secret_config(_name)
          {}
        end
      end

      def tty_stringio(str)
        io = StringIO.new(str)
        def io.tty?; true; end
        io
      end

      def prompt_step(extras = {})
        {
          "action" => "prompt_stdin_and_fill",
          "selector" => "input[name='otp']",
          "prompt" => "Enter code: ",
          "timeout" => 5
        }.merge(extras)
      end

      def build_runner(session:, schema:, stdin:, stdout: StringIO.new, stderr: StringIO.new, remote_prompt_store: nil)
        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: schema,
          context: {},
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: stdout,
          stderr: stderr,
          stdin: stdin,
          remote_prompt_store: remote_prompt_store
        )
      end

      def gate_runner(session:, steps:, runtime_context:, stdout: StringIO.new, resolver: FakeSecretResolver.new)
        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: PromptSchemaDouble.new(steps),
          context: {},
          secret_resolver: resolver,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: stdout,
          stderr: StringIO.new,
          runtime_context: runtime_context
        )
      end

      def test_when_context_gt_runs_step_when_condition_true
        session = FakeSession.new
        steps = [{
          "action" => "navigate",
          "url" => "https://bank.example/history",
          "when_context" => { "lookback_days" => { "gt" => 30 } }
        }]
        gate_runner(session: session, steps: steps, runtime_context: { lookback_days: 365 }).execute_phase("login")
        navigates = session.commands.select { |c| c[:method] == "Page.navigate" }
        assert_equal 1, navigates.size
      end

      def test_when_context_gt_skips_step_when_condition_false
        session = FakeSession.new
        stdout = StringIO.new
        steps = [{
          "action" => "navigate",
          "url" => "https://bank.example/history",
          "when_context" => { "lookback_days" => { "gt" => 30 } }
        }]
        gate_runner(session: session, steps: steps, runtime_context: { lookback_days: 14 }, stdout: stdout).execute_phase("login")
        assert_empty session.commands.select { |c| c[:method] == "Page.navigate" }
        assert_equal 1, stdout.string.scan("skipped (when_context)").size
        assert_includes stdout.string, "skipped (when_context): navigate"
      end

      def test_when_context_multiple_operators_are_anded
        steps_true = [{
          "action" => "navigate",
          "url" => "https://x",
          "when_context" => { "lookback_days" => { "gte" => 30, "lte" => 100 } }
        }]
        session_true = FakeSession.new
        gate_runner(session: session_true, steps: steps_true, runtime_context: { lookback_days: 50 }).execute_phase("login")
        assert_equal 1, session_true.commands.count { |c| c[:method] == "Page.navigate" }

        session_false = FakeSession.new
        gate_runner(session: session_false, steps: steps_true, runtime_context: { lookback_days: 200 }).execute_phase("login")
        assert_equal 0, session_false.commands.count { |c| c[:method] == "Page.navigate" }
      end

      def test_when_context_multiple_keys_are_anded
        session = FakeSession.new
        steps = [{
          "action" => "navigate",
          "url" => "https://x",
          "when_context" => {
            "lookback_days" => { "gt" => 30 },
            "isolated" => { "eq" => true }
          }
        }]
        gate_runner(session: session, steps: steps, runtime_context: { lookback_days: 365, isolated: false }).execute_phase("login")
        assert_equal 0, session.commands.count { |c| c[:method] == "Page.navigate" }
      end

      def test_when_context_unknown_operator_raises_at_runtime
        session = FakeSession.new
        steps = [{
          "action" => "navigate",
          "url" => "https://x",
          "when_context" => { "lookback_days" => { "between" => [1, 2] } }
        }]
        err = assert_raises(UserError) do
          gate_runner(session: session, steps: steps, runtime_context: { lookback_days: 50 }).execute_phase("login")
        end
        assert_includes err.message, "unknown operator"
        assert_includes err.message, "\"between\""
      end

      def test_when_context_non_numeric_value_for_gt_raises
        session = FakeSession.new
        steps = [{
          "action" => "navigate",
          "url" => "https://x",
          "when_context" => { "source_key" => { "gt" => 30 } }
        }]
        err = assert_raises(UserError) do
          gate_runner(session: session, steps: steps, runtime_context: { source_key: "ing" }).execute_phase("login")
        end
        assert_includes err.message, "source_key"
        assert_includes err.message, "numeric"
      end

      def test_when_context_missing_key_is_treated_as_nil
        session = FakeSession.new
        stdout = StringIO.new
        steps = [{
          "action" => "navigate",
          "url" => "https://x",
          "when_context" => { "lookback_days" => { "eq" => 30 } }
        }]
        gate_runner(session: session, steps: steps, runtime_context: {}, stdout: stdout).execute_phase("login")
        assert_equal 0, session.commands.count { |c| c[:method] == "Page.navigate" }
        assert_includes stdout.string, "skipped (when_context)"
      end

      def test_when_context_gate_does_not_resolve_secrets_on_skipped_step
        session = FakeSession.new
        resolver = FakeSecretResolver.new
        steps = [{
          "action" => "fill",
          "selector" => "#dni",
          "value" => "secret(USER_DNI)",
          "when_context" => { "lookback_days" => { "gt" => 30 } }
        }]
        gate_runner(session: session, steps: steps, runtime_context: { lookback_days: 14 }, resolver: resolver).execute_phase("login")
        assert_empty resolver.calls
        assert_empty session.commands.select { |c| c[:method] == "Runtime.evaluate" }
      end

      def test_fill_clear_runs_reset_before_typing
        session = FakeSession.new
        steps = [{
          "action" => "fill",
          "selector" => "#dni",
          "value" => "secret(USER_DNI)",
          "clear" => true
        }]
        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: PromptSchemaDouble.new(steps),
          context: {},
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: StringIO.new,
          stderr: StringIO.new
        ).execute_phase("login")

        runtime_exprs = session.commands.select { |c| c[:method] == "Runtime.evaluate" }.map { |c| c[:params][:expression] }
        assert(runtime_exprs.any? { |e| e.include?("dispatchEvent") && e.include?("'input'") },
               "expected a Runtime.evaluate that dispatches input event for clear")
        typed = session.commands.select { |c| c[:method] == "Input.dispatchKeyEvent" && c[:params][:type] == "char" }.map { |c| c[:params][:text] }
        assert_equal "12345678A".chars, typed.first("12345678A".length)
      end

      def test_fill_without_clear_does_not_dispatch_reset
        session = FakeSession.new
        steps = [{
          "action" => "fill",
          "selector" => "#dni",
          "value" => "secret(USER_DNI)"
        }]
        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: PromptSchemaDouble.new(steps),
          context: {},
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: StringIO.new,
          stderr: StringIO.new
        ).execute_phase("login")

        runtime_exprs = session.commands.select { |c| c[:method] == "Runtime.evaluate" }.map { |c| c[:params][:expression] }
        refute(runtime_exprs.any? { |e| e.include?("dispatchEvent") },
               "expected no clear dispatch when clear: is not set")
      end

      def test_fill_clear_raises_on_non_input_element
        session = FakeSession.new
        session.define_singleton_method(:send_command) do |method, params = {}, timeout: 30|
          @commands << { method: method, params: params, timeout: timeout }
          method == "Runtime.evaluate" ? { "result" => { "value" => "not-a-text-input" } } : {}
        end
        steps = [{ "action" => "fill", "selector" => "div.fake", "value" => "x", "clear" => true }]
        err = assert_raises(UserError) do
          BrowserWorkflowRunner.new(
            source: SourceDouble.new, session: session,
            schema: PromptSchemaDouble.new(steps), context: {},
            secret_resolver: FakeSecretResolver.new,
            session_drainer: ->(_s, iterations:, sleep_seconds:) {},
            stdout: StringIO.new, stderr: StringIO.new
          ).execute_phase("login")
        end
        assert_includes err.message, "requires <input> or <textarea>"
        assert_empty session.commands.select { |c| c[:method] == "Input.dispatchKeyEvent" }
      end

      def test_fill_if_present_with_clear_returns_silently_when_missing
        session = FakeSession.new
        session.define_singleton_method(:send_command) do |method, params = {}, timeout: 30|
          @commands << { method: method, params: params, timeout: timeout }
          method == "Runtime.evaluate" ? { "result" => { "value" => false } } : {}
        end
        steps = [{ "action" => "fill_if_present", "selector" => "#missing", "value" => "x", "clear" => true }]
        BrowserWorkflowRunner.new(
          source: SourceDouble.new, session: session,
          schema: PromptSchemaDouble.new(steps), context: {},
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_s, iterations:, sleep_seconds:) {},
          stdout: StringIO.new, stderr: StringIO.new
        ).execute_phase("login")
        assert_empty session.commands.select { |c| c[:method] == "Input.dispatchKeyEvent" }
      end

      def click_text_steps(extras = {})
        [{ "action" => "click_text", "text" => "Buscar" }.merge(extras)]
      end

      def click_text_runner(session:, steps:, stdout: StringIO.new)
        BrowserWorkflowRunner.new(
          source: SourceDouble.new, session: session,
          schema: PromptSchemaDouble.new(steps), context: {},
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_s, iterations:, sleep_seconds:) {},
          stdout: stdout, stderr: StringIO.new
        )
      end

      def test_click_text_dispatches_js_with_expected_args
        session = FakeSession.new
        click_text_runner(session: session, steps: click_text_steps).execute_phase("login")
        evals = session.commands.select { |c| c[:method] == "Runtime.evaluate" }
        assert_equal 1, evals.size
        expr = evals.first[:params][:expression]
        assert_includes expr, "\"Buscar\""
        assert_includes expr, "\"button\""
        assert_includes expr, "\"exact\""
        assert_includes expr, "deepQuery"
      end

      def test_click_text_passes_within_and_match
        session = FakeSession.new
        click_text_runner(
          session: session,
          steps: click_text_steps("within" => "#modal", "match" => "contains", "role" => "link")
        ).execute_phase("login")
        expr = session.commands.find { |c| c[:method] == "Runtime.evaluate" }[:params][:expression]
        assert_includes expr, "\"#modal\""
        assert_includes expr, "\"contains\""
        assert_includes expr, "\"link\""
      end

      def test_click_text_timeout_raises
        session = FakeSession.new
        session.define_singleton_method(:send_command) do |method, params = {}, timeout: 30|
          @commands << { method: method, params: params, timeout: timeout }
          method == "Runtime.evaluate" ? { "result" => { "value" => false } } : {}
        end
        err = assert_raises(UserError) do
          click_text_runner(
            session: session,
            steps: click_text_steps("timeout" => 1, "within" => ".scope")
          ).execute_phase("login")
        end
        assert_includes err.message, "click_text timed out"
        assert_includes err.message, "\"Buscar\""
        assert_includes err.message, ".scope"
      end

      def test_click_text_logs_action_and_text
        session = FakeSession.new
        stdout = StringIO.new
        click_text_runner(session: session, steps: click_text_steps, stdout: stdout).execute_phase("login")
        assert_includes stdout.string, "[yml] click_text: button \"Buscar\""
        assert_includes stdout.string, "✓"
      end

      def test_click_text_js_walker_contains_iframe_branch
        js = BrowserWorkflowRunner::CLICK_TEXT_JS
        assert_includes js, "IFRAME"
        assert_includes js, "contentDocument"
        assert_includes js, "catch"
        assert_includes js, "shadowRoot"
      end

      def test_click_text_js_is_injected_into_runtime_call
        session = FakeSession.new
        click_text_runner(session: session, steps: click_text_steps).execute_phase("login")
        expr = session.commands.find { |c| c[:method] == "Runtime.evaluate" }[:params][:expression]
        assert_includes expr, "contentDocument"
        assert_includes expr, "IFRAME"
      end

      def test_deep_query_fn_contains_iframe_traversal
        js = BrowserWorkflowRunner::DEEP_QUERY_FN
        assert_includes js, "IFRAME"
        assert_includes js, "contentDocument"
        assert_includes js, "catch"
        assert_includes js, "shadowRoot"
      end

      def test_deep_query_fn_is_injected_into_runtime_calls
        session = FakeSession.new
        steps = [{ "action" => "wait_for_selector", "selector" => "#target", "timeout" => 1 }]
        # session returns true by default => wait returns immediately
        BrowserWorkflowRunner.new(
          source: SourceDouble.new, session: session,
          schema: PromptSchemaDouble.new(steps), context: {},
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_s, iterations:, sleep_seconds:) {},
          stdout: StringIO.new, stderr: StringIO.new
        ).execute_phase("login")
        expr = session.commands.find { |c| c[:method] == "Runtime.evaluate" }[:params][:expression]
        assert_includes expr, "contentDocument"
      end

      def test_prompt_stdin_and_fill_happy_path
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step])
        stdin = tty_stringio("987654\n")
        stdout = StringIO.new
        stderr = StringIO.new

        build_runner(session: session, schema: schema, stdin: stdin, stdout: stdout, stderr: stderr).execute_phase("login")

        runtime_calls = session.commands.select { |c| c[:method] == "Runtime.evaluate" }
        assert_includes runtime_calls.first[:params][:expression], "input[name='otp']"

        typed = session.commands.select { |c| c[:method] == "Input.dispatchKeyEvent" && c[:params][:type] == "char" }.map { |c| c[:params][:text] }
        assert_equal %w[9 8 7 6 5 4], typed

        assert_includes stderr.string, "Enter code: "
        assert_includes stdout.string, "[yml] prompt_stdin_and_fill: filled input[name='otp']"
      end

      def test_prompt_stdin_and_fill_timeout
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step("timeout" => 1)])
        reader, _writer = IO.pipe
        def reader.tty?; true; end

        err = assert_raises(UserError) do
          build_runner(session: session, schema: schema, stdin: reader).execute_phase("login")
        end
        assert_includes err.message, "timed out"
        assert_includes err.message, "input[name='otp']"
      end

      def test_prompt_stdin_and_fill_rejects_non_tty
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step])
        stdin = StringIO.new("987654\n") # tty? -> false

        err = assert_raises(UserError) do
          build_runner(session: session, schema: schema, stdin: stdin).execute_phase("login")
        end
        assert_includes err.message, "non-tty"
        runtime_calls = session.commands.select { |c| c[:method] == "Runtime.evaluate" }
        assert_empty runtime_calls
      end

      def test_prompt_stdin_and_fill_rejects_empty_input
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step])
        stdin = tty_stringio("\n")

        err = assert_raises(UserError) do
          build_runner(session: session, schema: schema, stdin: stdin).execute_phase("login")
        end
        assert_includes err.message, "empty input"
      end

      def test_prompt_stdin_and_fill_escapes_payload
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step])
        payload = %q{abc"; alert(1)}
        stdin = tty_stringio(payload + "\n")

        build_runner(session: session, schema: schema, stdin: stdin).execute_phase("login")

        runtime_exprs = session.commands.select { |c| c[:method] == "Runtime.evaluate" }.map { |c| c[:params][:expression] }
        runtime_exprs.each do |expr|
          refute_includes expr, "alert(1)"
          refute_includes expr, payload
        end
      end

      def test_prompt_stdin_and_fill_does_not_log_value
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step])
        stdin = tty_stringio("987654\n")
        stdout = StringIO.new
        stderr = StringIO.new

        build_runner(session: session, schema: schema, stdin: stdin, stdout: stdout, stderr: stderr).execute_phase("login")

        refute_includes stdout.string, "987654"
        refute_includes stderr.string, "987654"
      end

      def test_prompt_stdin_and_fill_clicks_submit_when_provided
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step("submit_selector" => "button.go")])
        stdin = tty_stringio("987654\n")

        build_runner(session: session, schema: schema, stdin: stdin).execute_phase("login")

        runtime_exprs = session.commands.select { |c| c[:method] == "Runtime.evaluate" }.map { |c| c[:params][:expression] }
        assert(runtime_exprs.any? { |e| e.include?("button.go") }, "expected a Runtime.evaluate against submit selector")
      end

      # Mimics the real RemotePromptStore enough to exercise the runner's
      # interactive paths. The real store auto-announces to stderr when
      # constructed with announce_to:; this fake takes an `announce_to:`
      # kwarg on every prompt() call to keep the test surface explicit
      # without coupling to an instance-level IO. (The runner doesn't pass
      # announce_to: per-call, but the fake replays the same JSON-line
      # shape the real store would have written.)
      class FakeRemotePromptStore
        attr_reader :calls

        def initialize(value: nil, raise_timeout: false, announce_to: nil)
          @value = value
          @raise_timeout = raise_timeout
          @announce_to = announce_to
          @calls = []
        end

        def prompt(kind:, message:, mask: false, timeout_seconds:)
          @calls << { kind: kind, message: message, mask: mask, timeout_seconds: timeout_seconds }
          request = {
            "prompt_id"  => "p_fakeid01",
            "kind"       => kind.to_s,
            "message"    => message,
            "mask"       => mask,
            "expires_at" => "2030-01-01T00:00:00Z"
          }
          announce(request) if @announce_to
          yield "p_fakeid01", request if block_given?
          raise RemotePromptStore::Timeout, "fake" if @raise_timeout
          case kind
          when :input then @value || ""
          when :confirm then true
          end
        end

        private

        def announce(request)
          @announce_to.puts "[freentonic][prompt] #{JSON.generate(request)}"
          @announce_to.flush if @announce_to.respond_to?(:flush)
        end
      end

      def test_prompt_stdin_and_fill_falls_back_to_remote_when_non_tty
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step])
        stdin = StringIO.new("") # tty? -> false
        stderr = StringIO.new
        store = FakeRemotePromptStore.new(value: "987654", announce_to: stderr)

        build_runner(session: session, schema: schema, stdin: stdin, stderr: stderr, remote_prompt_store: store).execute_phase("login")

        assert_equal 1, store.calls.size
        call = store.calls.first
        assert_equal :input, call[:kind]
        assert_equal "Enter code: ", call[:message]
        assert_equal 5, call[:timeout_seconds]

        typed = session.commands.select { |c| c[:method] == "Input.dispatchKeyEvent" && c[:params][:type] == "char" }.map { |c| c[:params][:text] }
        assert_equal %w[9 8 7 6 5 4], typed

        # Log marker is on stderr, structured, no value
        assert_includes stderr.string, "[freentonic][prompt]"
        assert_includes stderr.string, "p_fakeid01"
        refute_includes stderr.string, "987654"
      end

      def test_prompt_stdin_and_fill_remote_timeout_raises_user_error
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step])
        stdin = StringIO.new("")
        store = FakeRemotePromptStore.new(raise_timeout: true)

        err = assert_raises(UserError) do
          build_runner(session: session, schema: schema, stdin: stdin, remote_prompt_store: store).execute_phase("login")
        end
        assert_includes err.message, "timed out"
        assert_includes err.message, "input[name='otp']"
      end

      def test_prompt_stdin_and_fill_remote_does_not_log_value
        session = FakeSession.new
        schema = PromptSchemaDouble.new([prompt_step])
        stdin = StringIO.new("")
        store = FakeRemotePromptStore.new(value: "TOPSECRET")
        stdout = StringIO.new
        stderr = StringIO.new

        build_runner(session: session, schema: schema, stdin: stdin, stdout: stdout, stderr: stderr, remote_prompt_store: store).execute_phase("login")

        refute_includes stdout.string, "TOPSECRET"
        refute_includes stderr.string, "TOPSECRET"
      end

      def test_prompt_stdin_and_fill_skipped_when_if_present_and_absent
        session = FakeSession.new
        session.define_singleton_method(:send_command) do |method, params = {}, timeout: 30|
          @commands << { method: method, params: params, timeout: timeout }
          method == "Runtime.evaluate" ? { "result" => { "value" => false } } : {}
        end
        schema = PromptSchemaDouble.new([prompt_step("if_present" => true)])
        # Reader that would raise if anyone tried to read from it
        stdin = Object.new
        def stdin.tty?; raise "should not be consulted"; end
        def stdin.gets; raise "should not be called"; end
        stdout = StringIO.new

        build_runner(session: session, schema: schema, stdin: stdin, stdout: stdout).execute_phase("login")

        assert_includes stdout.string, "skipped"
        keystroke_calls = session.commands.select { |c| c[:method] == "Input.dispatchKeyEvent" }
        assert_empty keystroke_calls
      end

      # ─── record_requests / dump_requests tests ───

      class RecordingSession
        attr_reader :commands, :pending_events

        def initialize
          @commands = []
          @pending_events = []
        end

        def send_command(method, params = {}, timeout: 30)
          @commands << { method: method, params: params, timeout: timeout }

          if method == "Runtime.evaluate"
            { "result" => { "value" => true } }
          elsif method == "Network.getResponseBody"
            request_id = params[:requestId]
            body_map = @_body_map || {}
            body_map[request_id] || { "body" => "", "base64Encoded" => false }
          else
            {}
          end
        end

        def stub_response_body(request_id, body, base64: false)
          @_body_map ||= {}
          @_body_map[request_id] = { "body" => body, "base64Encoded" => base64 }
        end

        def inject_request(request_id, url, method: "GET", headers: {}, post_data: nil)
          @pending_events << {
            "method" => "Network.requestWillBeSent",
            "params" => {
              "requestId" => request_id,
              "request" => { "url" => url, "method" => method, "headers" => headers, "postData" => post_data }
            }
          }
        end

        def inject_response(request_id, url, status: 200, headers: {})
          @pending_events << {
            "method" => "Network.responseReceived",
            "params" => {
              "requestId" => request_id,
              "response" => { "url" => url, "status" => status, "headers" => headers }
            }
          }
        end

        def inject_loading_finished(request_id)
          @pending_events << {
            "method" => "Network.loadingFinished",
            "params" => { "requestId" => request_id }
          }
        end
      end

      def recording_runner(session:, steps:, context: {}, stdout: StringIO.new)
        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: PromptSchemaDouble.new(steps),
          context: context,
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: stdout,
          stderr: StringIO.new
        )
      end

      def test_record_requests_captures_matching_urls
        session = RecordingSession.new
        context = {}

        session.inject_request("r1", "https://bank.example/apis/externo/accounts")
        session.inject_response("r1", "https://bank.example/apis/externo/accounts")
        session.inject_request("r2", "https://bank.example/apis/externo/movements")
        session.inject_response("r2", "https://bank.example/apis/externo/movements")
        session.inject_request("r3", "https://bank.example/static/logo.png")
        session.inject_response("r3", "https://bank.example/static/logo.png")

        steps = [
          { "action" => "record_requests", "url_matches" => ["bank.example/apis/externo/"] }
        ]
        recording_runner(session: session, steps: steps, context: context).execute_phase("login")

        log = context[:debug_request_log]
        assert_equal 2, log.size
        assert_includes log[0].dig("request", "url"), "accounts"
        assert_includes log[1].dig("request", "url"), "movements"
      end

      def test_record_requests_respects_max_entries
        session = RecordingSession.new
        context = {}
        max = 3

        7.times do |i|
          session.inject_request("r#{i}", "https://bank.example/api/item/#{i}")
          session.inject_response("r#{i}", "https://bank.example/api/item/#{i}")
        end

        steps = [
          { "action" => "record_requests", "url_matches" => ["bank.example/api/"], "max_entries" => max }
        ]
        recording_runner(session: session, steps: steps, context: context).execute_phase("login")

        log = context[:debug_request_log]
        assert_equal max, log.size
        # Oldest dropped, newest retained
        assert_includes log.last.dig("request", "url"), "item/6"
      end

      def test_record_requests_truncates_large_bodies
        session = RecordingSession.new
        context = {}
        max_body = 32

        session.inject_request("r1", "https://bank.example/api/big")
        session.inject_response("r1", "https://bank.example/api/big")
        session.inject_loading_finished("r1")
        session.stub_response_body("r1", "x" * 100)

        steps = [
          {
            "action" => "record_requests",
            "url_matches" => ["bank.example/api/"],
            "include_response_body" => true,
            "max_body_bytes" => max_body
          }
        ]
        recording_runner(session: session, steps: steps, context: context).execute_phase("login")

        log = context[:debug_request_log]
        assert_equal 1, log.size
        entry = log.first
        assert_equal max_body, entry.dig("response", "body")&.bytesize
        assert_equal true, entry.dig("response", "truncated")
      end

      def test_record_requests_decodes_base64_once
        session = RecordingSession.new
        context = {}

        session.inject_request("r1", "https://bank.example/api/binary")
        session.inject_response("r1", "https://bank.example/api/binary")
        session.inject_loading_finished("r1")
        session.stub_response_body("r1", Base64.strict_encode64("hello world"), base64: true)

        steps = [
          {
            "action" => "record_requests",
            "url_matches" => ["bank.example/api/"],
            "include_response_body" => true
          }
        ]
        recording_runner(session: session, steps: steps, context: context).execute_phase("login")

        log = context[:debug_request_log]
        assert_equal 1, log.size
        assert_equal "hello world", log.first.dig("response", "body")
      end

      def test_record_requests_does_not_record_body_when_include_body_false
        session = RecordingSession.new
        context = {}

        session.inject_request("r1", "https://bank.example/api/data")
        session.inject_response("r1", "https://bank.example/api/data")
        session.inject_loading_finished("r1")
        session.stub_response_body("r1", '{"secret":"data"}')

        steps = [
          { "action" => "record_requests", "url_matches" => ["bank.example/api/"] }
          # include_response_body defaults to false
        ]
        recording_runner(session: session, steps: steps, context: context).execute_phase("login")

        log = context[:debug_request_log]
        assert_equal 1, log.size
        assert_nil log.first.dig("response", "body")
      end

      def test_dump_requests_ndjson_roundtrip
        Dir.mktmpdir do |dir|
          session = RecordingSession.new
          context = {}

          3.times do |i|
            session.inject_request("r#{i}", "https://bank.example/api/item/#{i}")
            session.inject_response("r#{i}", "https://bank.example/api/item/#{i}")
          end

          path = File.join(dir, "capture.ndjson")
          steps = [
            { "action" => "record_requests", "url_matches" => ["bank.example/api/"] },
            { "action" => "dump_requests", "path" => path }
          ]
          recording_runner(session: session, steps: steps, context: context).execute_phase("login")

          lines = File.readlines(path).map(&:chomp).reject(&:empty?)
          assert_equal 3, lines.size
          lines.each do |line|
            parsed = JSON.parse(line)
            assert parsed.key?("request")
            refute parsed.key?("_request_id"), "internal keys should be stripped"
          end
        end
      end

      def test_dump_requests_reset_clears_buffer
        Dir.mktmpdir do |dir|
          session = RecordingSession.new
          context = {}

          session.inject_request("r1", "https://bank.example/api/data")
          session.inject_response("r1", "https://bank.example/api/data")

          path = File.join(dir, "capture.ndjson")
          steps = [
            { "action" => "record_requests", "url_matches" => ["bank.example/api/"] },
            { "action" => "dump_requests", "path" => path, "reset" => true }
          ]
          recording_runner(session: session, steps: steps, context: context).execute_phase("login")

          assert_equal 0, context[:debug_request_log].size
        end
      end

      def test_dump_requests_does_not_log_entries_or_bodies
        Dir.mktmpdir do |dir|
          session = RecordingSession.new
          context = {}

          session.inject_request("r1", "https://bank.example/api/secret-endpoint")
          session.inject_response("r1", "https://bank.example/api/secret-endpoint")

          path = File.join(dir, "capture.ndjson")
          stdout = StringIO.new
          steps = [
            { "action" => "record_requests", "url_matches" => ["bank.example/api/"] },
            { "action" => "dump_requests", "path" => path }
          ]
          recording_runner(session: session, steps: steps, context: context, stdout: stdout).execute_phase("login")

          refute_includes stdout.string, "secret-endpoint"
          refute_includes stdout.string, "bank.example/api"
          assert_includes stdout.string, "dump_requests: wrote"
        end
      end

      # ─── pause tests ───

      def test_pause_happy_path
        session = FakeSession.new
        schema = PromptSchemaDouble.new([{
          "action" => "pause",
          "message" => "Do something manually.",
          "timeout" => 5
        }])
        stdin = tty_stringio("\n")
        stdout = StringIO.new
        stderr = StringIO.new

        build_runner(session: session, schema: schema, stdin: stdin, stdout: stdout, stderr: stderr).execute_phase("login")

        assert_includes stdout.string, "pause: resumed after"
        assert_includes stderr.string, "Do something manually."
        assert_includes stderr.string, "[press Enter to continue]"
        # No Runtime.evaluate calls — pause doesn't touch the DOM
        runtime_calls = session.commands.select { |c| c[:method] == "Runtime.evaluate" }
        assert_empty runtime_calls
      end

      def test_pause_timeout
        session = FakeSession.new
        schema = PromptSchemaDouble.new([{
          "action" => "pause",
          "message" => "Wait here.",
          "timeout" => 1
        }])
        reader, _writer = IO.pipe
        def reader.tty?; true; end

        err = assert_raises(UserError) do
          build_runner(session: session, schema: schema, stdin: reader).execute_phase("login")
        end
        assert_includes err.message, "timed out"
      end

      def test_pause_rejects_non_tty
        session = FakeSession.new
        schema = PromptSchemaDouble.new([{
          "action" => "pause",
          "message" => "Wait here.",
          "timeout" => 5
        }])
        stdin = StringIO.new("\n") # tty? -> false

        err = assert_raises(UserError) do
          build_runner(session: session, schema: schema, stdin: stdin).execute_phase("login")
        end
        assert_includes err.message, "non-tty"
      end

      def test_pause_falls_back_to_remote_when_non_tty
        session = FakeSession.new
        schema = PromptSchemaDouble.new([{
          "action" => "pause",
          "message" => "Approve on your phone.",
          "timeout" => 5
        }])
        stdin = StringIO.new("") # tty? -> false
        stdout = StringIO.new
        stderr = StringIO.new
        store = FakeRemotePromptStore.new(announce_to: stderr)

        build_runner(session: session, schema: schema, stdin: stdin, stdout: stdout, stderr: stderr, remote_prompt_store: store).execute_phase("login")

        assert_equal 1, store.calls.size
        assert_equal :confirm, store.calls.first[:kind]
        assert_includes stdout.string, "pause: resumed after"
        assert_includes stderr.string, "[freentonic][prompt]"
      end

      def test_pause_remote_timeout_raises_user_error
        session = FakeSession.new
        schema = PromptSchemaDouble.new([{
          "action" => "pause",
          "message" => "Approve.",
          "timeout" => 1
        }])
        stdin = StringIO.new("")
        store = FakeRemotePromptStore.new(raise_timeout: true)

        err = assert_raises(UserError) do
          build_runner(session: session, schema: schema, stdin: stdin, remote_prompt_store: store).execute_phase("login")
        end
        assert_includes err.message, "timed out"
      end

      def test_pause_does_not_log_message
        session = FakeSession.new
        schema = PromptSchemaDouble.new([{
          "action" => "pause",
          "message" => "SECRET_INVESTIGATION_DETAILS",
          "timeout" => 5
        }])
        stdin = tty_stringio("\n")
        stdout = StringIO.new

        build_runner(session: session, schema: schema, stdin: stdin, stdout: stdout).execute_phase("login")

        refute_includes stdout.string, "SECRET_INVESTIGATION_DETAILS"
      end

      # ─── capture_url tests ───

      def test_capture_url_stores_in_context
        session = FakeSession.new
        context = {}
        schema = PromptSchemaDouble.new([{
          "action" => "capture_url",
          "as" => "current_page"
        }])
        stdout = StringIO.new

        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: schema,
          context: context,
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: stdout,
          stderr: StringIO.new
        ).execute_phase("login")

        # FakeSession returns true for Runtime.evaluate; current_url_value calls .to_s on it
        assert context.key?("current_page")
        assert_includes stdout.string, "capture_url: → ctx.current_page"
      end

      def test_capture_url_does_not_log_url
        session = FakeSession.new
        context = {}
        schema = PromptSchemaDouble.new([{
          "action" => "capture_url",
          "as" => "current_page"
        }])
        stdout = StringIO.new

        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: schema,
          context: context,
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: stdout,
          stderr: StringIO.new
        ).execute_phase("login")

        url_value = context["current_page"]
        # The log should contain the key name but not the URL value
        assert_includes stdout.string, "ctx.current_page"
        refute_includes stdout.string, url_value if url_value && !url_value.empty?
      end

      def test_capture_response_json_skips_excluded_urls
        session = FakeSession.new
        session.pending_events << {
          "method" => "Network.responseReceived",
          "params" => {
            "requestId" => "req-revoke",
            "response" => { "url" => "https://bank.example/oauth2/token/revoke" }
          }
        }
        context = {}

        BrowserWorkflowRunner.new(
          source: SourceDouble.new,
          session: session,
          schema: ResponseJsonSchemaDouble.new,
          context: context,
          secret_resolver: FakeSecretResolver.new,
          session_drainer: ->(_session, iterations:, sleep_seconds:) {},
          stdout: StringIO.new,
          stderr: StringIO.new
        ).execute_phase("capture_credentials")

        assert_nil context["access_token"]
      end
    end
  end
