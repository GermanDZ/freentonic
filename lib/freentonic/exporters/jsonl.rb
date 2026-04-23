# frozen_string_literal: true

module Freentonic
  module Exporters
    # Writes the canonical payload's transactions slot as NDJSON. Delegates
    # to the configured Formatter (default: jsonl_transactions). The
    # formatter owns the row-shaping logic — see
    # lib/freentonic/formatters/jsonl_transactions.rb.
    #
    # Options:
    #   path:   "out.jsonl" or "-"/nil for stdout
    #   format: formatter name (default :jsonl_transactions)
    #
    # Requires a CanonicalPayload as input. Plain Hash payloads raise
    # UserError pointing at the canonical migration — there is no longer a
    # generic --export-csv-select fallback.
    class Jsonl < Base
      def write(payload)
        unless payload.is_a?(Canonical::CanonicalPayload)
          raise UserError,
                "jsonl exporter now requires a CanonicalPayload (post-migration). " \
                "Update your normalizer to return Canonical::CanonicalPayload — " \
                "see docs/canonical-data-model.md and docs/canonical-migration-plan.md."
        end

        formatter = resolve_formatter
        body = formatter.call(payload)

        open_output(@options[:path]) do |io|
          io.write(body)
        end
      end

      def default_format
        :jsonl_transactions
      end
    end

    register(:jsonl, Jsonl)
  end
end
