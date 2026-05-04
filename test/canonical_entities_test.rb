# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "date"
require "time"

module Freentonic
  module Canonical
    class EntitiesTest < Minitest::Test
      # ---------- Balance ----------

      def test_balance_coerces_strings_and_numerics_to_bigdecimal
        bal = Balance.new(current: "1200.50", available: 1150.20, timestamp: "2026-04-23T10:00:00Z")
        assert_equal BigDecimal("1200.50"), bal.current
        assert_equal BigDecimal("1150.20"), bal.available
        assert_equal Time.utc(2026, 4, 23, 10, 0, 0), bal.timestamp
      end

      def test_balance_allows_all_nil
        bal = Balance.new
        assert_nil bal.current
        assert_nil bal.available
        assert_nil bal.timestamp
        assert_equal({ "current" => nil, "available" => nil, "timestamp" => nil }, bal.to_h)
      end

      def test_balance_to_h_uses_wire_formats
        bal = Balance.new(current: "1200.50", available: "1150.20",
                          timestamp: Time.utc(2026, 4, 23, 10, 0, 0))
        assert_equal "1200.5", bal.to_h["current"]
        assert_equal "1150.2", bal.to_h["available"]
        assert_equal "2026-04-23T10:00:00Z", bal.to_h["timestamp"]
      end

      def test_balance_is_immutable
        bal = Balance.new(current: "10")
        assert_raises(NoMethodError, FrozenError) { bal.current = BigDecimal("20") }
      end

      # ---------- Merchant ----------

      def test_merchant_defaults
        m = Merchant.new(name: "Amazon")
        assert_equal "Amazon", m.name
        assert_equal false, m.normalized
      end

      def test_merchant_to_h
        m = Merchant.new(name: "Amazon", normalized: true)
        assert_equal({ "name" => "Amazon", "normalized" => true }, m.to_h)
      end

      # ---------- Account ----------

      def test_account_required_fields
        acct = Account.new(id: "acc_1", currency: "EUR")
        assert_equal "acc_1", acct.id
        assert_equal "EUR", acct.currency
        assert_nil acct.iban
        assert_nil acct.balance
        assert_nil acct.portable_id
        assert_equal({}, acct.metadata)
      end

      def test_account_portable_id_round_trips_to_wire_shape
        acct = Account.new(id: "acc_1", currency: "EUR",
                           portable_id: "bank:1465:1272")
        assert_equal "bank:1465:1272", acct.portable_id
        assert_equal "bank:1465:1272", acct.to_h["portable_id"]
      end

      def test_account_rejects_unknown_keyword
        assert_raises(ArgumentError) do
          Account.new(id: "a1", currency: "EUR", nonexistent_field: "x")
        end
      end

      def test_account_coerces_hash_balance
        acct = Account.new(id: "acc_1", currency: "EUR",
                           balance: { current: "1200.50", available: "1150.20",
                                      timestamp: "2026-04-23T10:00:00Z" })
        assert_instance_of Balance, acct.balance
        assert_equal BigDecimal("1200.50"), acct.balance.current
      end

      def test_account_to_h_wire_shape
        acct = Account.new(
          id: "acc_1", source_id: "12345", institution: "bbva",
          name: "Main Account", type: "checking", currency: "EUR",
          iban: "ES12345", balance: { current: "1200.50" }, metadata: { "branch" => "001" }
        )
        h = acct.to_h
        assert_equal "acc_1", h["id"]
        assert_equal "12345", h["source_id"]
        assert_equal "bbva", h["institution"]
        assert_equal "Main Account", h["name"]
        assert_equal "checking", h["type"]
        assert_equal "EUR", h["currency"]
        assert_equal "ES12345", h["iban"]
        assert_equal "1200.5", h["balance"]["current"]
        assert_equal({ "branch" => "001" }, h["metadata"])
      end

      # ---------- Transaction ----------

      def test_transaction_required_fields
        txn = Transaction.new(id: "txn_1", account_id: "acc_1",
                              amount: "-45.20", currency: "EUR")
        assert_equal BigDecimal("-45.20"), txn.amount
        assert_nil txn.date
        assert_nil txn.value_date
      end

      def test_transaction_parses_iso_dates
        txn = Transaction.new(id: "txn_1", account_id: "acc_1", amount: "0",
                              currency: "EUR", date: "2026-04-20",
                              value_date: "2026-04-21")
        assert_equal Date.new(2026, 4, 20), txn.date
        assert_equal Date.new(2026, 4, 21), txn.value_date
      end

      def test_transaction_coerces_hash_merchant
        txn = Transaction.new(id: "txn_1", account_id: "acc_1", amount: "0",
                              currency: "EUR",
                              merchant: { name: "Amazon", normalized: true })
        assert_instance_of Merchant, txn.merchant
        assert_equal "Amazon", txn.merchant.name
      end

      def test_transaction_to_h_wire_shape
        txn = Transaction.new(
          id: "txn_1", account_id: "acc_1", amount: "-45.20", currency: "EUR",
          date: "2026-04-20", value_date: "2026-04-21",
          description: "Amazon", raw_description: "AMZN Mktp ES*XYZ",
          status: "posted", merchant: { name: "Amazon", normalized: true }
        )
        h = txn.to_h
        assert_equal "-45.2", h["amount"]
        assert_equal "2026-04-20", h["date"]
        assert_equal "2026-04-21", h["value_date"]
        assert_equal({ "name" => "Amazon", "normalized" => true }, h["merchant"])
      end

      def test_transaction_missing_required_raises
        assert_raises(ArgumentError) do
          Transaction.new(id: "t1", account_id: "a1", amount: "0")  # missing currency
        end
      end

      # ---------- Liability ----------

      def test_liability_required_fields
        liab = Liability.new(id: "liab_1", type: "credit_card", currency: "EUR")
        assert_equal "credit_card", liab.type
        assert_nil liab.account_id
        assert_nil liab.balance
      end

      def test_liability_to_h
        liab = Liability.new(id: "liab_1", type: "credit_card", currency: "EUR",
                             account_id: "acc_1", balance: "-500.00",
                             limit: "2000.00", due_date: "2026-05-01")
        h = liab.to_h
        assert_equal "-500.0", h["balance"]
        assert_equal "2000.0", h["limit"]
        assert_equal "2026-05-01", h["due_date"]
      end

      # ---------- Investment ----------

      def test_investment_required_fields
        inv = Investment.new(id: "inv_1", account_id: "acc_1",
                             symbol: "AAPL", currency: "USD")
        assert_equal "AAPL", inv.symbol
        assert_nil inv.quantity
      end

      def test_investment_to_h
        inv = Investment.new(id: "inv_1", account_id: "acc_1",
                             symbol: "AAPL", currency: "USD",
                             type: "stock", quantity: "10", price: "170.25")
        h = inv.to_h
        assert_equal "10.0", h["quantity"]
        assert_equal "170.25", h["price"]
        assert_equal "stock", h["type"]
      end

      # ---------- Structural equality ----------

      def test_entities_are_value_equal
        a = Account.new(id: "acc_1", currency: "EUR", name: "Main")
        b = Account.new(id: "acc_1", currency: "EUR", name: "Main")
        assert_equal a, b
        assert_equal a.hash, b.hash
      end
    end
  end
end
