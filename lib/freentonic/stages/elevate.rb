# frozen_string_literal: true

require "date"

module Freentonic
  module Stages
    # Elevate stage: the session-elevation lifecycle moment between Connect
    # and Extract. Runs the workflow's `elevate:` step sequence against the
    # api_client — conditionally on a block-level `when:` gate — so a
    # provider can perform a PSD2 SCA handshake (operator approval + Bearer
    # rotation) declaratively instead of in an extractor.rb.
    #
    # No-op when the workflow declares no `elevate:` block, so providers
    # without one see zero behavior change.
    #
    # Load-bearing detail: it builds the api_client and stashes it in
    # context[:api_client]; the Extract stage reuses that same instance, so
    # a rebind_credential rotation performed here is visible downstream.
    # (build_api_client mints a fresh client per call — without the stash
    # the mutation would be lost.)
    class Elevate < Base
      def call
        spec = schema.elevate_spec
        return @context if spec.nil?

        stdout.puts "\nElevating session..."
        from_date = Date.today - @context.fetch(:lookback_days)
        scope     = Freentonic::ExtractPlan.seed_scope(from_date)

        unless Freentonic::ExtractPlan::WhenGate.passes?(spec["when"], scope)
          stdout.puts "  when: not met — skipping elevation"
          return @context
        end

        client = build_client
        run_elevation(spec, client, scope)
        @context
      end

      private

      def build_client
        client = schema.build_api_client(@context[:credentials])
        unless client
          raise UserError, "elevate: requires an api_client: block (its steps fetch declared endpoints)"
        end
        @context[:api_client] = client
      end

      def run_elevation(spec, client, scope)
        interpreter(spec).run(client: client, scope: scope)
        stdout.puts "  session elevated ✓"
      rescue StandardError => e
        handle_failure(spec, e)
      end

      def interpreter(spec)
        Freentonic::Elevate::Interpreter.new(
          steps:          Array(spec["steps"]),
          endpoint_names: schema.api_client_endpoint_names,
          stdout:         stdout,
          stderr:         stderr,
          prompt_store:   build_remote_prompt_store
        )
      end

      # on_failure: degrade → warn and continue with the un-elevated
      # (captured) credential; abort (the default) → fail the run. On
      # degrade the stashed client is dropped so Extract rebuilds a pristine
      # one — "continue with the captured Bearer" must not inherit a
      # half-applied elevation.
      def handle_failure(spec, error)
        if mandatory?(spec)
          # An already-actionable UserError (e.g. await's no-channel note)
          # keeps its own message; anything else gets wrapped.
          raise error if error.is_a?(UserError)
          raise UserError, "Session elevation failed: #{error.message}"
        end

        @context.delete(:api_client)
        stderr.puts "  ⚠ elevation failed (#{error.class}: #{error.message}) — " \
                    "continuing with the un-elevated session"
      end

      def mandatory?(spec)
        (spec["on_failure"] || "abort").to_s != "degrade"
      end
    end
  end
end
