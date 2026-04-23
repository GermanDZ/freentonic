# frozen_string_literal: true

require "json"

module Freentonic
  module Formatters
    # NDJSON variant of CsvTransactions — one JSON object per line, each
    # object being the transaction's wire hash with account context hoisted
    # as `account_name` / `account_currency` / `account_institution`.
    #
    # Trailing newline included so concatenating multiple payloads stays
    # newline-separated.
    class JsonlTransactions < Base
      def call(payload)
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

      def content_type
        "application/x-ndjson"
      end
    end

    register(:jsonl_transactions, JsonlTransactions)
  end
end
