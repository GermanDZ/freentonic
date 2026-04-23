# frozen_string_literal: true

require_relative "test_helper"
require "json"

module Freentonic
  module Canonical
    class PayloadTest < Minitest::Test
      def build_payload(summary: CanonicalPayload::AUTO)
        CanonicalPayload.new(
          accounts: [Account.new(id: "acc_1", currency: "EUR",
                                 balance: { current: "1200.50" })],
          transactions: [
            Transaction.new(id: "txn_1", account_id: "acc_1",
                            amount: "-45.20", currency: "EUR",
                            date: "2026-04-20")
          ],
          meta: { "scraper_version" => "1.0.0" },
          summary: summary
        )
      end

      def test_schema_version_is_pinned_on_wire
        p = build_payload
        assert_equal "0.1", p.schema_version
        assert_equal "0.1", p.to_h["schema_version"]
      end

      def test_envelope_carries_all_slots
        p = build_payload
        h = p.to_h
        assert_equal ["schema_version", "summary", "meta", "accounts",
                      "transactions", "liabilities", "investments"].sort,
                     h.keys.sort
      end

      def test_summary_auto_computed
        p = build_payload
        assert_equal 1, p.summary["counts"]["accounts"]
        assert_equal 1, p.summary["counts"]["transactions"]
        assert_equal "-45.2", p.summary["amounts_by_currency"]["EUR"]
      end

      def test_summary_override_passes_through_untouched
        p = build_payload(summary: { "custom" => "rollup" })
        assert_equal({ "custom" => "rollup" }, p.summary)
        assert_equal({ "custom" => "rollup" }, p.to_h["summary"])
      end

      def test_summary_nil_disables_computation
        p = build_payload(summary: nil)
        assert_nil p.summary
        assert_nil p.to_h["summary"]
      end

      def test_round_trip_via_json
        p = build_payload
        parsed = ::JSON.parse(::JSON.generate(p.to_h))
        assert_equal "0.1", parsed["schema_version"]
        assert_equal "txn_1", parsed["transactions"].first["id"]
        assert_equal "-45.2", parsed["transactions"].first["amount"]
        assert_equal "2026-04-20", parsed["transactions"].first["date"]
      end

      def test_empty_slots_default_to_arrays
        p = CanonicalPayload.new
        h = p.to_h
        assert_equal [], h["accounts"]
        assert_equal [], h["transactions"]
        assert_equal [], h["liabilities"]
        assert_equal [], h["investments"]
      end

      def test_payload_is_frozen
        p = CanonicalPayload.new
        assert_predicate p, :frozen?
        assert_predicate p.accounts, :frozen?
        assert_predicate p.meta, :frozen?
      end

      def test_structural_equality
        a = build_payload(summary: nil)
        b = build_payload(summary: nil)
        assert_equal a, b
      end
    end
  end
end
