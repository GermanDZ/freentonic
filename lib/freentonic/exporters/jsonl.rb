# frozen_string_literal: true

require "json"

module Freentonic
  module Exporters
    # Writes the canonical payload's transactions slot as NDJSON — one JSON
    # object per line, with newline terminators.
    #
    # Options:
    #   path: "out.jsonl" or "-"/nil for stdout
    #
    # Requires a CanonicalPayload as input. Plain Hash payloads raise
    # UserError pointing at the canonical migration.
    #
    # Each line is the transaction's `to_h` plus three hoisted columns from
    # the owning account (`account_name` / `account_currency` /
    # `account_institution`). Orphan transactions emit `null` for those
    # fields.
    class Jsonl < Base
      def write(payload)
        unless payload.is_a?(Canonical::CanonicalPayload)
          raise UserError,
                "jsonl exporter requires a CanonicalPayload. " \
                "Update your normalizer to return Canonical::CanonicalPayload — " \
                "see docs/canonical-data-model.md."
        end

        body = render(payload)
        open_output(@options[:path]) do |io|
          io.write(body)
        end
      end

      private

      def render(payload)
        accounts_by_id = payload.accounts.each_with_object({}) { |a, h| h[a.id] = a }
        lines = payload.transactions.map do |txn|
          account = accounts_by_id[txn.account_id]
          row = txn.to_h
          row["account_name"] = account&.name
          row["account_currency"] = account&.currency
          row["account_institution"] = account&.institution
          ::JSON.generate(row)
        end
        return "" if lines.empty?
        lines.join("\n") + "\n"
      end
    end

    register(:jsonl, Jsonl)
  end
end
