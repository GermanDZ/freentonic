# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require "json"

module Freentonic
  module Stages
    class ExtractTest < Minitest::Test
      # Minimal source double — just the surface Extract reads from.
      WorkflowDouble = Struct.new(:api_client, :extract_config, :path) do
        def build_api_client(_credentials); api_client; end
        def config; { "extract" => extract_config }; end
      end
      SourceDouble = Struct.new(:workflow, :extract_spec)

      # Subclass the stage so the test can inject the extractor instance
      # without writing a Ruby file to disk and require-loading it.
      class ExtractWithInjectedExtractor < Extract
        def initialize(context:, extractor:)
          super(context: context)
          @injected = extractor
        end
        private
        def load_extractor; @injected; end
      end

      def make_context(stderr: StringIO.new, stdout: StringIO.new, lookback_days: 30, credentials: {})
        workflow = WorkflowDouble.new(:fake_client, { "ruby" => "x", "class" => "X" }, "/tmp/fake/workflow.yml")
        {
          source:        SourceDouble.new(workflow, nil),
          credentials:   credentials,
          lookback_days: lookback_days,
          stdout:        stdout,
          stderr:        stderr
        }
      end

      def run_stage(extractor, env: {}, **ctx_overrides)
        ctx = make_context(**ctx_overrides)
        with_env(env) do
          ExtractWithInjectedExtractor.new(context: ctx, extractor: extractor).call
        end
        ctx
      end

      def with_env(env)
        previous = env.keys.each_with_object({}) { |k, h| h[k] = ENV[k] }
        env.each { |k, v| ENV[k] = v }
        yield
      ensure
        previous&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      end

      # ── back-compat: legacy extractors keep working ─────────────────────

      class LegacyExtractor
        attr_reader :received
        def call(client:, credentials:, from_date:, stdout:, stderr:)
          @received = { client: client, credentials: credentials, from_date: from_date,
                        stdout: stdout, stderr: stderr }
          { "ok" => true }
        end
      end

      def test_legacy_extractor_signature_does_not_receive_new_kwargs
        # Pre-existing providers (ING / Unicaja / Fintonic / Revolut) declare
        # only the original 5 kwargs. The stage MUST NOT pass anything else
        # through to them, or every provider's tests would ArgumentError on
        # the next gem bump.
        ex = LegacyExtractor.new
        Dir.mktmpdir("rd") do |d|
          ctx = run_stage(ex, env: { "FREENTONIC_RUN_DIR" => d })
          assert_equal({ "ok" => true }, ctx[:raw])
          assert_equal :fake_client, ex.received[:client]
          refute ex.received.key?(:remote_prompt_store)
          refute ex.received.key?(:run_dir)
        end
      end

      # ── opt-in: extractors that declare the new kwargs receive them ─────

      class ScaAwareExtractor
        attr_reader :received
        def call(client:, credentials:, from_date:, stdout:, stderr:,
                 remote_prompt_store: nil, run_dir: nil)
          @received = { client: client, credentials: credentials, from_date: from_date,
                        stdout: stdout, stderr: stderr,
                        remote_prompt_store: remote_prompt_store, run_dir: run_dir }
          {}
        end
      end

      def test_sca_aware_extractor_receives_prompt_store_and_run_dir
        ex = ScaAwareExtractor.new
        Dir.mktmpdir("rd") do |d|
          run_stage(ex, env: { "FREENTONIC_RUN_DIR" => d })
          assert_kind_of RemotePromptStore, ex.received[:remote_prompt_store]
          assert_equal d, ex.received[:run_dir]
          assert_equal File.join(d, "prompts"), ex.received[:remote_prompt_store].prompts_dir
        end
      end

      def test_remote_prompt_store_is_nil_when_run_dir_unset
        ex = ScaAwareExtractor.new
        run_stage(ex, env: { "FREENTONIC_RUN_DIR" => nil })
        assert_nil ex.received[:remote_prompt_store]
        assert_nil ex.received[:run_dir]
      end

      def test_extractor_prompt_announces_to_stage_stderr
        # End-to-end: an extractor opens a confirm prompt and the JSON-line
        # announcement lands on the stage's stderr (which the invoke runner
        # forwards to simplefreen-invoke). The fixture posts a response from
        # a thread so the prompt resolves quickly.
        Dir.mktmpdir("rd") do |d|
          stderr = StringIO.new
          ex = Class.new do
            def initialize(prompts_dir); @prompts_dir = prompts_dir; end
            def call(client:, credentials:, from_date:, stdout:, stderr:,
                     remote_prompt_store:, run_dir:)
              # Watcher thread: drop a response file as soon as the request
              # appears.
              t = Thread.new do
                deadline = Time.now + 5
                until (req = Dir.glob(File.join(@prompts_dir, "*.request.json")).first)
                  return if Time.now > deadline
                  sleep 0.05
                end
                pid = File.basename(req, ".request.json")
                File.write(File.join(@prompts_dir, "#{pid}.response.json"),
                           JSON.generate({ "confirmed" => true }))
              end
              ok = remote_prompt_store.prompt(kind: :confirm, message: "Approve in app", timeout_seconds: 5)
              t.join
              { "approved" => ok }
            end
          end.new(File.join(d, "prompts"))

          ctx = run_stage(ex, env: { "FREENTONIC_RUN_DIR" => d }, stderr: stderr)
          assert_equal({ "approved" => true }, ctx[:raw])
          assert_includes stderr.string, "[freentonic][prompt]"
          announcement_line = stderr.string.lines.find { |l| l.start_with?("[freentonic][prompt]") }
          payload = JSON.parse(announcement_line.sub("[freentonic][prompt] ", ""))
          assert_equal "confirm", payload["kind"]
          assert_equal "Approve in app", payload["message"]
        end
      end

      # ── opt-in via **kwargs: extractor receives every framework kwarg ───

      class GreedyExtractor
        attr_reader :received
        def call(**kwargs); @received = kwargs; {}; end
      end

      def test_extractor_with_kwargs_capture_receives_all
        ex = GreedyExtractor.new
        Dir.mktmpdir("rd") do |d|
          run_stage(ex, env: { "FREENTONIC_RUN_DIR" => d })
        end
        %i[client credentials from_date stdout stderr remote_prompt_store run_dir].each do |k|
          assert ex.received.key?(k), "expected greedy extractor to receive #{k.inspect}"
        end
      end

      # ── SessionExpired surfaces as an actionable UserError ──────────────

      class ExpiredSessionExtractor
        def call(**); raise ApiClient::SessionExpired, "session expired (HTTP 401)"; end
      end

      def test_session_expired_becomes_actionable_user_error
        err = assert_raises(UserError) { run_stage(ExpiredSessionExtractor.new) }
        assert_includes err.message, "session expired (HTTP 401)"
        assert_includes err.message, "Re-run connect"
      end
    end
  end
end
