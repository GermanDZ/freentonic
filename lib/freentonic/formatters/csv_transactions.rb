# frozen_string_literal: true

require "csv"
require "json"

module Freentonic
  module Formatters
    # Flattens the canonical `transactions` slot to CSV rows, hoisting
    # context fields from the owning account as `account_name` /
    # `account_currency` / `account_institution` columns. The transaction
    # already carries `account_id`, so we don't re-hoist that one.
    #
    # Orphan transactions (account_id not present in payload.accounts) emit
    # a row with the account_* columns blank — never an error.
    #
    # Column order: union of all row keys, sorted ASCII-ascending.
    # Determinism matters for diffing.
    #
    # Nested structures (`merchant`, `metadata`) are JSON-stringified into
    # a single cell. Money fields are already strings (from to_h).
    class CsvTransactions < Base
      ACCOUNT_HOIST_KEYS = %w[account_name account_currency account_institution].freeze

      def call(payload)
        accounts_by_id = payload.accounts.each_with_object({}) { |a, h| h[a.id] = a }
        rows = payload.transactions.map { |txn| build_row(txn, accounts_by_id[txn.account_id]) }
        return "" if rows.empty?

        headers = rows.flat_map(&:keys).uniq.sort
        ::CSV.generate do |csv|
          csv << headers
          rows.each { |row| csv << headers.map { |h| stringify(row[h]) } }
        end
      end

      def content_type
        "text/csv"
      end

      private

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

    register(:csv_transactions, CsvTransactions)
  end
end
