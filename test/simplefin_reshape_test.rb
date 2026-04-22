# frozen_string_literal: true

require_relative "test_helper"
require "freentonic/simplefin/reshape"

module Freentonic
  module Simplefin
    class ReshapeTest < Minitest::Test
      def sample
        {
          "source_tag" => "ing",
          "accounts" => [
            {
              "external_id"   => "12345",
              "bank_name"     => "ING",
              "currency"      => "EUR",
              "balance_cents" => 123_456,
              "balance_at"    => "2026-04-22T10:00:00Z",
              "movements" => [
                { "dedup_key" => "m1", "amount_cents" => -500,
                  "date" => "2026-04-21", "description" => "Coffee" },
                { "amount_cents" => 1000,
                  "date" => "2026-04-20", "description" => "Refund",
                  "payee" => "Acme Inc" }
              ]
            }
          ]
        }
      end

      def test_reshape_produces_simplefin_envelope
        env = Reshape.call(sample)
        assert_equal 1, env["accounts"].size
        account = env["accounts"].first
        assert_equal "12345", account["id"]
        assert_equal "EUR", account["currency"]
        assert_equal "1234.56", account["balance"]
        assert_equal Time.parse("2026-04-22T10:00:00Z").to_i, account["balance-date"]
        assert_equal "ING", account["org"]["name"]
        assert_equal [], env["errors"]
      end

      def test_movements_reshape_and_get_stable_ids
        env = Reshape.call(sample)
        txs = env["accounts"].first["transactions"]
        assert_equal 2, txs.size
        assert_equal "m1", txs[0]["id"]              # provider-assigned
        assert_match(/\A[0-9a-f]{24}\z/, txs[1]["id"])  # synthesized
        assert_equal "-5.00", txs[0]["amount"]
        assert_equal "10.00", txs[1]["amount"]
        assert_equal "Acme Inc", txs[1]["payee"]
      end

      def test_missing_currency_emits_error_and_skips_account
        payload = sample
        payload["accounts"].first.delete("currency")
        env = Reshape.call(payload)
        assert_empty env["accounts"]
        assert_match(/12345/, env["errors"].first)
        assert_match(/currency/, env["errors"].first)
      end

      def test_missing_balance_date_emits_error
        payload = sample
        payload["accounts"].first.delete("balance_at")
        env = Reshape.call(payload)
        assert_empty env["accounts"]
        assert_match(/balance-date/, env["errors"].first)
      end

      def test_stable_id_ignores_case_and_whitespace_in_description
        a = { "amount_cents" => -500, "date" => "2026-04-21", "description" => " Coffee " }
        b = { "amount_cents" => -500, "date" => "2026-04-21", "description" => "coffee" }
        assert_equal Reshape.stable_tx_id("acct", a), Reshape.stable_tx_id("acct", b)
      end

      def test_apply_query_filters_by_start_date
        env = Reshape.call(sample)
        cutoff = Time.parse("2026-04-21").to_i
        filtered = Reshape.apply_query(env, { "start-date" => cutoff.to_s })
        assert_equal 1, filtered["accounts"].first["transactions"].size
      end

      def test_apply_query_balances_only
        env = Reshape.call(sample)
        filtered = Reshape.apply_query(env, { "balances-only" => "1" })
        assert_empty filtered["accounts"].first["transactions"]
      end

      def test_apply_query_account_filter
        payload = sample
        payload["accounts"] << payload["accounts"].first.merge("external_id" => "67890")
        env = Reshape.call(payload)
        filtered = Reshape.apply_query(env, { "account" => ["12345"] })
        assert_equal ["12345"], filtered["accounts"].map { |a| a["id"] }
      end

      def test_cents_to_decimal_handles_negative_and_zero
        assert_equal "-5.00", Reshape.cents_to_decimal(-500)
        assert_equal "0.00", Reshape.cents_to_decimal(0)
        assert_equal "0.01", Reshape.cents_to_decimal(1)
        assert_equal "-0.01", Reshape.cents_to_decimal(-1)
      end
    end
  end
end
