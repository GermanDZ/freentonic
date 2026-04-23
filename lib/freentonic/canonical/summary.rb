# frozen_string_literal: true

require "bigdecimal"
require "time"

module Freentonic
  module Canonical
    # Framework-computed rollup over a payload's entities. Called from
    # CanonicalPayload.new unless the author passes an explicit summary.
    module Summary
      module_function

      def compute(accounts:, transactions:, liabilities:, investments:)
        {
          "counts" => {
            "accounts" => accounts.length,
            "transactions" => transactions.length,
            "liabilities" => liabilities.length,
            "investments" => investments.length
          },
          "amounts_by_currency" => sum_by_currency(transactions, :amount),
          "balances_by_currency" => balances_by_currency(accounts),
          "date_range" => date_range(transactions),
          "generated_at" => Time.now.utc.iso8601
        }
      end

      def sum_by_currency(entities, amount_attr)
        totals = Hash.new { |h, k| h[k] = BigDecimal("0") }
        entities.each do |entity|
          amt = entity.public_send(amount_attr)
          next if amt.nil?
          totals[entity.currency] += amt
        end
        totals.transform_values { |v| v.to_s("F") }
      end

      def balances_by_currency(accounts)
        totals = Hash.new { |h, k| h[k] = BigDecimal("0") }
        accounts.each do |acct|
          next if acct.balance.nil? || acct.balance.current.nil?
          totals[acct.currency] += acct.balance.current
        end
        totals.transform_values { |v| v.to_s("F") }
      end

      # Returns { "earliest" => "YYYY-MM-DD", "latest" => "YYYY-MM-DD" } over
      # non-nil transaction dates, or nil when no transaction has a date.
      def date_range(transactions)
        dates = transactions.map(&:date).compact
        return nil if dates.empty?
        min, max = dates.minmax
        { "earliest" => min.iso8601, "latest" => max.iso8601 }
      end
    end
  end
end
