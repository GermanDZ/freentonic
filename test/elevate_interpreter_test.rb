# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "date"

module Freentonic
  module Elevate
    class InterpreterTest < Minitest::Test
      # Fake client: endpoint methods return canned data and record calls;
      # update_auth_headers! records the rotation the way rebind_credential
      # drives it.
      class FakeClient
        attr_reader :calls, :rebinds

        def initialize(responses: {})
          @responses = responses
          @calls     = []
          @rebinds   = []
        end

        def sca_challenge
          @calls << [:sca_challenge, {}]
          @responses.fetch(:sca_challenge, {})
        end

        def sca_commit(process_id:)
          @calls << [:sca_commit, { process_id: process_id }]
          @responses.fetch(:sca_commit, {})
        end

        def refresh_access_token
          @calls << [:refresh_access_token, {}]
          @responses.fetch(:refresh_access_token, {})
        end

        def update_auth_headers!(headers, host: nil)
          @rebinds << { headers: headers, host: host }
          self
        end
      end

      # Fake prompt store mirroring RemotePromptStore#prompt's surface.
      class FakePromptStore
        attr_reader :prompts

        def initialize(raise_timeout: false)
          @raise_timeout = raise_timeout
          @prompts       = []
        end

        def prompt(kind:, message:, mask:, timeout_seconds:)
          @prompts << { kind: kind, message: message, mask: mask, timeout_seconds: timeout_seconds }
          raise RemotePromptStore::Timeout, "timed out" if @raise_timeout
          true
        end
      end

      ENDPOINTS = %w[sca_challenge sca_commit refresh_access_token].freeze

      def run_elevate(steps, client:, prompt_store: FakePromptStore.new,
                      from_date: Date.new(2026, 1, 1), stdout: StringIO.new, stderr: StringIO.new)
        scope = ExtractPlan.seed_scope(from_date)
        Interpreter.new(steps: steps, endpoint_names: ENDPOINTS,
                        stdout: stdout, stderr: stderr, prompt_store: prompt_store)
                   .run(client: client, scope: scope)
      end

      # ── await_operator_approval ─────────────────────────────────────────

      def test_await_issues_confirm_prompt_with_interpolated_message
        client = FakeClient.new(responses: {
          sca_challenge: { "acceptanceMethods" => [{ "code" => "AC-42" }] }
        })
        store = FakePromptStore.new
        steps = [
          { "fetch" => "sca_challenge", "as" => "challenge" },
          { "await_operator_approval" => {
            "message" => "approve {challenge.acceptanceMethods.0.code} on your phone",
            "timeout" => 90
          } }
        ]
        run_elevate(steps, client: client, prompt_store: store)

        assert_equal 1, store.prompts.size
        p = store.prompts.first
        assert_equal :confirm, p[:kind]
        assert_equal "approve AC-42 on your phone", p[:message]
        assert_equal 90, p[:timeout_seconds]
      end

      def test_await_defaults_timeout
        store = FakePromptStore.new
        steps = [{ "await_operator_approval" => { "message" => "approve" } }]
        run_elevate(steps, client: FakeClient.new, prompt_store: store)
        assert_equal Interpreter::DEFAULT_APPROVAL_TIMEOUT, store.prompts.first[:timeout_seconds]
      end

      def test_await_without_prompt_store_raises_rather_than_hanging
        steps = [{ "await_operator_approval" => { "message" => "approve" } }]
        err = assert_raises(UserError) do
          run_elevate(steps, client: FakeClient.new, prompt_store: nil)
        end
        assert_includes err.message, "no operator channel"
      end

      def test_await_timeout_propagates
        steps = [{ "await_operator_approval" => { "message" => "approve" } }]
        assert_raises(RemotePromptStore::Timeout) do
          run_elevate(steps, client: FakeClient.new, prompt_store: FakePromptStore.new(raise_timeout: true))
        end
      end

      # ── rebind_credential ───────────────────────────────────────────────

      def test_rebind_installs_interpolated_header_on_client
        client = FakeClient.new(responses: {
          refresh_access_token: { "accessTokens" => [{ "accessToken" => "NEWTOKEN" }] }
        })
        steps = [
          { "fetch" => "refresh_access_token", "as" => "refreshed" },
          { "rebind_credential" => {
            "header" => "Authorization",
            "host"   => "api.ing.ingdirect.es",
            "value"  => "Bearer {refreshed.accessTokens.0.accessToken}"
          } }
        ]
        run_elevate(steps, client: client)

        assert_equal 1, client.rebinds.size
        assert_equal({ "Authorization" => "Bearer NEWTOKEN" }, client.rebinds.first[:headers])
        assert_equal "api.ing.ingdirect.es", client.rebinds.first[:host]
      end

      def test_rebind_without_host_passes_nil_host
        client = FakeClient.new(responses: { refresh_access_token: { "t" => "abc" } })
        steps = [
          { "fetch" => "refresh_access_token", "as" => "refreshed" },
          { "rebind_credential" => { "header" => "X-Auth", "value" => "{refreshed.t}" } }
        ]
        run_elevate(steps, client: client)
        assert_nil client.rebinds.first[:host]
        assert_equal({ "X-Auth" => "abc" }, client.rebinds.first[:headers])
      end

      def test_rebind_nil_token_fails
        client = FakeClient.new(responses: { refresh_access_token: {} })
        steps = [
          { "fetch" => "refresh_access_token", "as" => "refreshed" },
          { "rebind_credential" => { "header" => "Authorization",
                                     "value" => "Bearer {refreshed.accessTokens.0.accessToken}" } }
        ]
        err = assert_raises(UserError) { run_elevate(steps, client: client) }
        assert_includes err.message, "rebind_credential[Authorization]"
        assert_empty client.rebinds
      end

      # ── composition + shared verbs + when: ──────────────────────────────

      def test_full_sca_sequence_threads_bindings
        client = FakeClient.new(responses: {
          sca_challenge:        { "acceptanceMethods" => [{ "securityProcessId" => "PID-7", "code" => "C1" }] },
          sca_commit:           { "ok" => true },
          refresh_access_token: { "accessTokens" => [{ "accessToken" => "HI-LOA" }] }
        })
        steps = [
          { "fetch" => "sca_challenge", "as" => "challenge" },
          { "await_operator_approval" => { "message" => "approve {challenge.acceptanceMethods.0.code}" } },
          { "fetch" => "sca_commit", "args" => { "process_id" => "{challenge.acceptanceMethods.0.securityProcessId}" } },
          { "fetch" => "refresh_access_token", "as" => "refreshed" },
          { "rebind_credential" => { "header" => "Authorization", "host" => "api.ing.ingdirect.es",
                                     "value" => "Bearer {refreshed.accessTokens.0.accessToken}" } }
        ]
        run_elevate(steps, client: client)

        assert_equal %i[sca_challenge sca_commit refresh_access_token], client.calls.map(&:first)
        assert_equal({ process_id: "PID-7" }, client.calls[1][1])
        assert_equal({ "Authorization" => "Bearer HI-LOA" }, client.rebinds.first[:headers])
      end

      def test_step_when_gate_skips_rebind
        client = FakeClient.new(responses: { refresh_access_token: { "t" => "x" } })
        steps = [
          { "fetch" => "refresh_access_token", "as" => "refreshed" },
          { "rebind_credential" => { "header" => "X", "value" => "{refreshed.t}" },
            "when" => { "lookback_days" => { "gt" => 999 } } }
        ]
        # from_date 1 day ago → lookback_days 1, gate 1>999 false → skipped
        run_elevate(steps, client: client, from_date: Date.today - 1)
        assert_empty client.rebinds
      end
    end
  end
end
