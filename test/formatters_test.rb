# frozen_string_literal: true

require_relative "test_helper"
require "csv"
require "json"

module Freentonic
  class FormattersTest < Minitest::Test
    # `Canonical` inside `Freentonic::Formatters` resolves to the formatter
    # class, not the data-model module — so this file deliberately stays at
    # the `Freentonic::` level and refers to formatter classes via their
    # fully qualified names.
    Formatters = ::Freentonic::Formatters
    Canonical = ::Freentonic::Canonical
      # ---------- Shared fixture ----------

      def fixture_payload
        Canonical::CanonicalPayload.new(
          accounts: [
            Canonical::Account.new(
              id: "acc_eur", institution: "bbva", name: "Main EUR",
              type: "checking", currency: "EUR",
              balance: { current: "1200.50" }
            ),
            Canonical::Account.new(
              id: "acc_usd", institution: "chase", name: "Main USD",
              type: "checking", currency: "USD"
            )
          ],
          transactions: [
            Canonical::Transaction.new(
              id: "txn_a", account_id: "acc_eur", amount: "-45.20",
              currency: "EUR", date: "2026-04-20",
              description: "Amazon", raw_description: "AMZN Mktp ES*XYZ",
              status: "posted",
              merchant: { name: "Amazon", normalized: true }
            ),
            Canonical::Transaction.new(
              id: "txn_b", account_id: "acc_usd", amount: "100.00",
              currency: "USD", date: "2026-04-21",
              description: "Salary", raw_description: "PAYROLL DEPOSIT",
              status: "pending"
            ),
            Canonical::Transaction.new(  # orphan: account_id not in accounts
              id: "txn_orphan", account_id: "acc_missing", amount: "5.00",
              currency: "EUR", date: "2026-04-22",
              raw_description: "stray"
            )
          ],
          summary: nil  # disable so tests aren't time-dependent
        )
      end

      # ---------- Registry ----------

      def test_registered_lists_all_three_built_ins
        assert_includes Formatters.registered, :canonical
        assert_includes Formatters.registered, :csv_transactions
        assert_includes Formatters.registered, :jsonl_transactions
      end

      def test_build_returns_correct_class
        assert_instance_of Formatters::Canonical, Formatters.build(:canonical)
        assert_instance_of Formatters::CsvTransactions, Formatters.build(:csv_transactions)
        assert_instance_of Formatters::JsonlTransactions, Formatters.build(:jsonl_transactions)
      end

      def test_build_accepts_string_or_symbol
        assert_instance_of Formatters::Canonical, Formatters.build("canonical")
      end

      def test_build_unknown_name_raises_with_helpful_message
        err = assert_raises(UserError) { Formatters.build(:nope) }
        assert_match(/unknown format :nope/, err.message)
        assert_match(/canonical/, err.message)
      end

      # ---------- Canonical ----------

      def test_canonical_returns_payload_to_h
        out = Formatters.build(:canonical).call(fixture_payload)
        assert_kind_of Hash, out
        assert_equal "0.1", out["schema_version"]
        assert_equal 3, out["transactions"].length
      end

      def test_canonical_round_trips_via_json
        formatter = Formatters.build(:canonical)
        wire = ::JSON.generate(formatter.call(fixture_payload))
        parsed = ::JSON.parse(wire)
        assert_equal "txn_a", parsed["transactions"].first["id"]
        assert_equal "-45.2", parsed["transactions"].first["amount"]
      end

      def test_canonical_content_type
        assert_equal "application/json", Formatters.build(:canonical).content_type
      end

      # ---------- CsvTransactions ----------

      def test_csv_content_type
        assert_equal "text/csv", Formatters.build(:csv_transactions).content_type
      end

      def test_csv_headers_are_deterministic_and_sorted
        out = Formatters.build(:csv_transactions).call(fixture_payload)
        first_line = out.lines.first.strip
        headers = ::CSV.parse_line(first_line)
        assert_equal headers.sort, headers, "headers must be sorted ASCII-ascending"
        # account_* hoist columns present
        assert_includes headers, "account_name"
        assert_includes headers, "account_currency"
        assert_includes headers, "account_institution"
        # txn fields present
        assert_includes headers, "amount"
        assert_includes headers, "raw_description"
      end

      def test_csv_emits_one_row_per_transaction
        out = Formatters.build(:csv_transactions).call(fixture_payload)
        rows = ::CSV.parse(out, headers: true)
        assert_equal 3, rows.length
      end

      def test_csv_hoists_account_context
        out = Formatters.build(:csv_transactions).call(fixture_payload)
        rows = ::CSV.parse(out, headers: true)
        eur_row = rows.find { |r| r["id"] == "txn_a" }
        assert_equal "Main EUR", eur_row["account_name"]
        assert_equal "EUR", eur_row["account_currency"]
        assert_equal "bbva", eur_row["account_institution"]
      end

      def test_csv_orphan_transaction_emits_blank_account_columns
        out = Formatters.build(:csv_transactions).call(fixture_payload)
        rows = ::CSV.parse(out, headers: true)
        orphan = rows.find { |r| r["id"] == "txn_orphan" }
        refute_nil orphan
        # CSV.parse returns either nil or "" for an empty cell depending on
        # version/quoting; both are equivalent "blank" outcomes here.
        assert_includes [nil, ""], orphan["account_name"]
        assert_includes [nil, ""], orphan["account_currency"]
        assert_includes [nil, ""], orphan["account_institution"]
      end

      def test_csv_amount_is_string_not_float
        out = Formatters.build(:csv_transactions).call(fixture_payload)
        rows = ::CSV.parse(out, headers: true)
        eur_row = rows.find { |r| r["id"] == "txn_a" }
        assert_equal "-45.2", eur_row["amount"]
      end

      def test_csv_nested_structures_json_stringified
        out = Formatters.build(:csv_transactions).call(fixture_payload)
        rows = ::CSV.parse(out, headers: true)
        eur_row = rows.find { |r| r["id"] == "txn_a" }
        merchant = ::JSON.parse(eur_row["merchant"])
        assert_equal({ "name" => "Amazon", "normalized" => true }, merchant)
      end

      def test_csv_empty_payload_produces_empty_string
        empty = Canonical::CanonicalPayload.new(summary: nil)
        assert_equal "", Formatters.build(:csv_transactions).call(empty)
      end

      # ---------- JsonlTransactions ----------

      def test_jsonl_content_type
        assert_equal "application/x-ndjson",
                     Formatters.build(:jsonl_transactions).content_type
      end

      def test_jsonl_one_object_per_line
        out = Formatters.build(:jsonl_transactions).call(fixture_payload)
        lines = out.lines.map(&:strip).reject(&:empty?)
        assert_equal 3, lines.length
        lines.each { |l| ::JSON.parse(l) }  # all valid JSON
      end

      def test_jsonl_hoists_account_context
        out = Formatters.build(:jsonl_transactions).call(fixture_payload)
        first = ::JSON.parse(out.lines.first)
        assert_equal "Main EUR", first["account_name"]
        assert_equal "EUR", first["account_currency"]
        assert_equal "bbva", first["account_institution"]
      end

      def test_jsonl_orphan_account_columns_are_null
        out = Formatters.build(:jsonl_transactions).call(fixture_payload)
        orphan_line = out.lines.find { |l| l.include?("txn_orphan") }
        orphan = ::JSON.parse(orphan_line)
        assert_nil orphan["account_name"]
        assert_nil orphan["account_currency"]
        assert_nil orphan["account_institution"]
      end

      def test_jsonl_trailing_newline_present
        out = Formatters.build(:jsonl_transactions).call(fixture_payload)
        assert out.end_with?("\n"), "jsonl output must end with newline"
      end

      def test_jsonl_empty_payload_produces_empty_string
        empty = Canonical::CanonicalPayload.new(summary: nil)
        assert_equal "", Formatters.build(:jsonl_transactions).call(empty)
      end
  end
end
