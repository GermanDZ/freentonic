# frozen_string_literal: true

require "time"
require "date"
require_relative "extract_plan/scope"
require_relative "extract_plan/when_gate"
require_relative "extract_plan/interpreter"

module Freentonic
  # Declarative extractor: the `extract: plan:` form. Interprets a small,
  # closed grammar (fetch → for_each → collect → assemble) over the
  # workflow's declarative api_client endpoints, so a provider whose
  # extractor is pure orchestration needs zero Ruby.
  #
  # PlanExtractor is duck-typed exactly like a provider's Ruby extractor
  # class — same `#call(client:, credentials:, from_date:, stdout:,
  # stderr:)` surface, same raw-hash return — so the Extract stage treats
  # it identically and everything downstream (context[:raw], --from-raw,
  # the normalizer) is unchanged. The `{ruby:, class:}` escape hatch stays
  # for extractors that need imperative control flow (SCA handshakes,
  # raw_request, mid-flow header rotation); a plan can express none of
  # those by design.
  module ExtractPlan
    # Build the pre-seeded Scope shared by both the extract plan and the
    # elevate phase, so a `when:` gate or template sees the same bindings
    # in either locus: `from_date`, `from_ms`, `now_ms`, `today`,
    # `lookback_days`. Kept in one place so PLAN_SEED_BINDINGS (the static
    # validator's seed set) and the runtime seed can never drift apart.
    def self.seed_scope(from_date, today: Date.today)
      scope = Scope.new
      scope.bind("from_date", from_date)
      scope.bind("from_ms", from_date.nil? ? nil : from_date.to_time.to_i * 1000)
      scope.bind("now_ms", (Time.now.to_f * 1000).to_i)
      scope.bind("today", today)
      scope.bind("lookback_days", from_date.nil? ? nil : (today - from_date).to_i)
      scope
    end

    class PlanExtractor
      # @param plan [Hash] the validated `extract.plan` block.
      # @param endpoint_names [Array<String>] the workflow's declared
      #   api_client endpoint names — the whitelist `fetch:` resolves
      #   against (see Interpreter#invoke).
      def initialize(plan, endpoint_names:)
        @plan           = plan || {}
        @endpoint_names = endpoint_names
      end

      # Base 5-kwarg signature only: plans never do SCA, so they don't
      # accept remote_prompt_store/run_dir. The stage's kwarg filtering
      # (see Stages::Extract#call_extractor) means those are simply not
      # passed.
      def call(client:, credentials:, from_date:, stdout:, stderr:)
        scope = ExtractPlan.seed_scope(from_date)
        Interpreter.new(@plan, endpoint_names: @endpoint_names,
                        stdout: stdout, stderr: stderr)
                   .run(client: client, scope: scope)
      end
    end
  end
end
