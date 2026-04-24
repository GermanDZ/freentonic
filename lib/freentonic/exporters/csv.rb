# frozen_string_literal: true

require "csv"
require "json"

module Freentonic
  module Exporters
    # Writes the canonical payload's transactions slot as CSV.
    #
    # Options:
    #   path: "out.csv" or "-"/nil for stdout
    #
    # Requires a CanonicalPayload as input. Plain Hash payloads raise
    # UserError pointing at the canonical migration.
    #
    # Row shape: each transaction's `to_h` plus three hoisted columns from
    # the owning account (`account_name` / `account_currency` /
    # `account_institution`). Orphan transactions (account_id not in
    # payload.accounts) emit blank account_* columns — never an error.
    #
    # Column order: union of all row keys, sorted ASCII-ascending.
    # Determinism matters for diffing.
    #
    # Nested structures (`merchant`, `metadata`) are JSON-stringified into
    # a single cell. Money fields are already strings (from to_h).
    class Csv < Base
      def write(payload)
        unless payload.is_a?(Canonical::CanonicalPayload)
          raise UserError,
                "csv exporter requires a CanonicalPayload. " \
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
        rows = payload.transactions.map { |txn| build_row(txn, accounts_by_id[txn.account_id]) }
        return "" if rows.empty?

        headers = rows.flat_map(&:keys).uniq.sort
        ::CSV.generate do |csv|
          csv << headers
          rows.each { |row| csv << headers.map { |h| stringify(row[h]) } }
        end
      end

      def build_row(txn, account)
        row = txn.to_h
        row["account_name"] = account&.name
        row["account_currency"] = account&.currency
        row["account_institution"] = account&.institution
        row
      end

      def stringify(value)
        case value
        when nil then ""
        when String then value
        when Hash, Array then ::JSON.generate(value)
        else value.to_s
        end
      end
    end

    register(:csv, Csv)
  end
end
