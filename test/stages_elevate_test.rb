# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

module Freentonic
  module Stages
    class ElevateTest < Minitest::Test
      class FakeClient
        attr_reader :rebinds
        def initialize(responses: {})
          @responses = responses
          @rebinds   = []
        end

        def refresh_access_token
          @responses.fetch(:refresh_access_token, {})
        end

        def boom
          raise ApiClient::SessionExpired, "401"
        end

        def update_auth_headers!(headers, host: nil)
          @rebinds << { headers: headers, host: host }
          self
        end
      end

      class FakePromptStore
        def prompt(**) = true
      end

      # Workflow double exposing just what the Elevate stage reads.
      WorkflowDouble = Struct.new(:elevate_spec, :client, :endpoint_names) do
        def build_api_client(_credentials) = client
        def api_client_endpoint_names = endpoint_names
      end
      SourceDouble = Struct.new(:workflow)

      # Inject the prompt store so tests never touch the filesystem channel.
      class ElevateWithStore < Elevate
        def initialize(context:, store:)
          super(context: context)
          @store = store
        end
        private
        def build_remote_prompt_store = @store
      end

      def make_context(spec:, client:, lookback_days: 120, endpoints: %w[refresh_access_token boom])
        {
          source:        SourceDouble.new(WorkflowDouble.new(spec, client, endpoints)),
          credentials:   {},
          lookback_days: lookback_days,
          stdout:        StringIO.new,
          stderr:        StringIO.new
        }
      end

      def run_stage(ctx, store: FakePromptStore.new)
        ElevateWithStore.new(context: ctx, store: store).call
        ctx
      end

      # ── no-op / gating ──────────────────────────────────────────────────

      def test_no_elevate_block_is_a_noop
        ctx = make_context(spec: nil, client: FakeClient.new)
        run_stage(ctx)
        refute ctx.key?(:api_client)
      end

      def test_when_not_met_skips_without_building_client
        spec = {
          "when"  => { "lookback_days" => { "gt" => 90 } },
          "steps" => [{ "rebind_credential" => { "header" => "X", "value" => "y" } }]
        }
        ctx = make_context(spec: spec, client: FakeClient.new, lookback_days: 30) # 30 !> 90
        run_stage(ctx)
        refute ctx.key?(:api_client), "should not build a client when the gate fails"
      end

      # ── success ─────────────────────────────────────────────────────────

      def test_successful_elevation_stashes_client_and_rebinds
        client = FakeClient.new(responses: {
          refresh_access_token: { "accessTokens" => [{ "accessToken" => "TOK" }] }
        })
        spec = {
          "when"  => { "lookback_days" => { "gt" => 90 } },
          "steps" => [
            { "fetch" => "refresh_access_token", "as" => "refreshed" },
            { "rebind_credential" => { "header" => "Authorization", "host" => "api.ing.ingdirect.es",
                                       "value" => "Bearer {refreshed.accessTokens.0.accessToken}" } }
          ]
        }
        ctx = make_context(spec: spec, client: client)
        run_stage(ctx)

        assert_same client, ctx[:api_client], "Extract must reuse the elevated client"
        assert_equal({ "Authorization" => "Bearer TOK" }, client.rebinds.first[:headers])
      end

      # ── on_failure policy ───────────────────────────────────────────────

      def test_on_failure_degrade_warns_and_drops_client
        spec = {
          "on_failure" => "degrade",
          "steps"      => [{ "fetch" => "boom", "as" => "x" }] # SessionExpired
        }
        ctx = make_context(spec: spec, client: FakeClient.new)
        run_stage(ctx) # does not raise

        refute ctx.key?(:api_client), "degrade drops the client so Extract rebuilds pristine"
        assert_includes ctx[:stderr].string, "un-elevated"
      end

      def test_on_failure_abort_default_raises
        spec = { "steps" => [{ "fetch" => "boom", "as" => "x" }] } # no on_failure → abort
        ctx = make_context(spec: spec, client: FakeClient.new)
        assert_raises(UserError) { run_stage(ctx) }
      end

      def test_await_without_channel_aborts_by_default
        spec = { "steps" => [{ "await_operator_approval" => { "message" => "approve" } }] }
        ctx = make_context(spec: spec, client: FakeClient.new)
        err = assert_raises(UserError) { run_stage(ctx, store: nil) }
        assert_includes err.message, "no operator channel"
      end

      def test_await_without_channel_degrades_when_asked
        spec = {
          "on_failure" => "degrade",
          "steps"      => [{ "await_operator_approval" => { "message" => "approve" } }]
        }
        ctx = make_context(spec: spec, client: FakeClient.new)
        run_stage(ctx, store: nil) # does not raise
        assert_includes ctx[:stderr].string, "un-elevated"
      end
    end
  end
end
