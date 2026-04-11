require_relative "test_helper"
require "stringio"

module Freentonic
    class BrowserWorkflowRunnerTest < Minitest::Test
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
              "host" => "univia.unicajabanco.es",
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
          { "name" => "sid", "value" => "abc", "domain" => ".univia.unicajabanco.es", "path" => "/services/rest/" }
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

      class ResponseJsonSchemaDouble
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
