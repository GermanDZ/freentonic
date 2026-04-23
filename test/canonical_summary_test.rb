# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"

module Freentonic
  module Canonical
    class SummaryTest < Minitest::Test
      def sample_accounts
        [
          Account.new(id: "acc_eur", currency: "EUR",
                      balance: { current: "1200.50" }),
          Account.new(id: "acc_eur2", currency: "EUR",
                      balance: { current: "300.00" }),
          Account.new(id: "acc_usd", currency: "USD",
                      balance: { current: "1000.00" }),
          Account.new(id: "acc_nobal", currency: "GBP")
        ]
      end

      def sample_txns
        [
          Transaction.new(id: "t1", account_id: "acc_eur", amount: "-45.20",
                          currency: "EUR", date: "2026-04-20"),
          Transaction.new(id: "t2", account_id: "acc_eur", amount: "100.00",
                          currency: "EUR", date: "2026-04-22"),
          Transaction.new(id: "t3", account_id: "acc_usd", amount: "500.00",
                          currency: "USD", date: "2026-03-01"),
          Transaction.new(id: "t4", account_id: "acc_nobal", amount: "10",
                          currency: "GBP") # no date → skipped in date_range
        ]
      end

      def test_counts
        summary = Summary.compute(accounts: sample_accounts, transactions: sample_txns,
                                  liabilities: [], investments: [])
        assert_equal({ "accounts" => 4, "transactions" => 4,
                       "liabilities" => 0, "investments" => 0 }, summary["counts"])
      end

      def test_amounts_by_currency_uses_bigdecimal_precision
        summary = Summary.compute(accounts: [], transactions: sample_txns,
                                  liabilities: [], investments: [])
        assert_equal "54.8", summary["amounts_by_currency"]["EUR"]
        assert_equal "500.0", summary["amounts_by_currency"]["USD"]
        assert_equal "10.0", summary["amounts_by_currency"]["GBP"]
      end

      def test_balances_by_currency_skips_nil_balances
        summary = Summary.compute(accounts: sample_accounts, transactions: [],
                                  liabilities: [], investments: [])
        assert_equal "1500.5", summary["balances_by_currency"]["EUR"]
        assert_equal "1000.0", summary["balances_by_currency"]["USD"]
        refute summary["balances_by_currency"].key?("GBP")
      end

      def test_date_range_over_non_nil_dates
        summary = Summary.compute(accounts: [], transactions: sample_txns,
                                  liabilities: [], investments: [])
        assert_equal({ "earliest" => "2026-03-01", "latest" => "2026-04-22" },
                     summary["date_range"])
      end

      def test_date_range_nil_when_no_dated_transactions
        txn = Transaction.new(id: "t", account_id: "a", amount: "1", currency: "EUR")
        summary = Summary.compute(accounts: [], transactions: [txn],
                                  liabilities: [], investments: [])
        assert_nil summary["date_range"]
      end

      def test_generated_at_is_iso8601_utc
        summary = Summary.compute(accounts: [], transactions: [], liabilities: [], investments: [])
        assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, summary["generated_at"])
      end
    end
  end
end
