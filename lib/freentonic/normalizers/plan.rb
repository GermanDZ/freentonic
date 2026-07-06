# frozen_string_literal: true

require "date"

module Freentonic
  module Normalizers
    # Declarative normalizer: the `normalize: plan:` form. Runs the same
    # plan interpreter as `extract: plan:` — with no api_client and fetch:
    # statically excluded — so normalization is a *total, offline*
    # computation: raw in, canonical out, replayable via --from-raw
    # forever, with zero provider-authored code executing.
    #
    # Seeded scope: `raw` (the extract payload), `config` (the provider's
    # config.yml, top-level keys re-stringified so `{config.status_map}`
    # digs work), and `today`. Deliberately NOT now_ms/from_ms — a
    # normalize plan that read the clock would silently break replay.
    #
    # Output contract: the plan's output: binds `accounts` /
    # `transactions` / optional `liabilities` (entity lists built via
    # apply: build_account / build_transaction / build_liability); this
    # class assembles the CanonicalPayload envelope itself with
    # config.yml's scraper_version. Plans never build the envelope.
    class Plan < Base
      def initialize(plan, config:, stdout: $stdout, stderr: $stderr)
        @plan   = plan || {}
        @config = config || {}
        @stdout = stdout
        @stderr = stderr
      end

      def call(raw, context: {})
        scope = ExtractPlan::Scope.new
        scope.bind("raw", raw)
        scope.bind("config", @config.transform_keys(&:to_s))
        scope.bind("today", Date.today)

        out = ExtractPlan::Interpreter
              .new(@plan, endpoint_names: [], stdout: @stdout, stderr: @stderr)
              .run(client: nil, scope: scope)

        Providers::CanonicalBuilder.payload(
          accounts:        Array(out["accounts"]),
          transactions:    Array(out["transactions"]),
          liabilities:     Array(out["liabilities"]),
          scraper_version: @config[:scraper_version]
        )
      end
    end
  end
end
