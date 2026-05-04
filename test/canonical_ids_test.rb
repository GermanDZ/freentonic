# frozen_string_literal: true

require_relative "test_helper"
require "date"

module Freentonic
  module Canonical
    class IdsTest < Minitest::Test
      def test_transaction_id_is_deterministic
        args = {
          account_id: "acc_xyz",
          date: Date.new(2026, 4, 20),
          amount: "-45.20",
          raw_description: "AMZN Mktp ES*XYZ"
        }
        assert_equal Canonical.transaction_id(**args),
                     Canonical.transaction_id(**args)
      end

      def test_transaction_id_is_prefixed_and_16_hex
        id = Canonical.transaction_id(account_id: "a", date: "2026-01-01",
                                      amount: "10", raw_description: "x")
        assert_match(/\Atxn_[0-9a-f]{16}\z/, id)
      end

      def test_transaction_id_normalizes_amount_scale
        id1 = Canonical.transaction_id(account_id: "a", date: "2026-01-01",
                                       amount: "45.20", raw_description: "x")
        id2 = Canonical.transaction_id(account_id: "a", date: "2026-01-01",
                                       amount: "45.2", raw_description: "x")
        assert_equal id1, id2, "45.20 and 45.2 are the same number and must hash identically"
      end

      def test_transaction_id_strips_raw_description_whitespace
        id1 = Canonical.transaction_id(account_id: "a", date: "2026-01-01",
                                       amount: "1", raw_description: "  foo  ")
        id2 = Canonical.transaction_id(account_id: "a", date: "2026-01-01",
                                       amount: "1", raw_description: "foo")
        assert_equal id1, id2
      end

      def test_transaction_id_differs_on_different_inputs
        id1 = Canonical.transaction_id(account_id: "a", date: "2026-01-01",
                                       amount: "1", raw_description: "x")
        id2 = Canonical.transaction_id(account_id: "a", date: "2026-01-02",
                                       amount: "1", raw_description: "x")
        refute_equal id1, id2
      end

      def test_transaction_id_distinguishes_distinct_source_ids
        # Repro: two ING Kepler debits on the same date/amount/desc used to
        # collapse to a single id and get deduped by SimpleFIN clients.
        base = {
          account_id: "acc_1", date: "2026-05-04", amount: "-680",
          raw_description: "KEPLER"
        }
        id1 = Canonical.transaction_id(**base, source_id: "v1id-aaaa")
        id2 = Canonical.transaction_id(**base, source_id: "v1id-bbbb")
        refute_equal id1, id2
        assert_match(/\Atxn_[0-9a-f]{16}\z/, id1)
        assert_match(/\Atxn_[0-9a-f]{16}\z/, id2)
      end

      def test_transaction_id_falls_back_to_legacy_derivation_when_source_id_blank
        # Same-provider mixed presence: rows without a source_id keep hashing
        # off the (account_id, date, amount, raw_description) tuple.
        legacy = Canonical.transaction_id(
          account_id: "a", date: "2026-01-01", amount: "1", raw_description: "x"
        )
        [nil, "", "   "].each do |blank|
          assert_equal legacy,
                       Canonical.transaction_id(
                         account_id: "a", date: "2026-01-01",
                         amount: "1", raw_description: "x", source_id: blank
                       )
        end
      end

      def test_transaction_id_source_id_branch_ignores_other_components
        # When source_id wins, date/amount/desc don't enter the hash — so a
        # later sync that re-fetches the same upstream row with a corrected
        # date or cleaned description still produces the same canonical id.
        a = Canonical.transaction_id(
          account_id: "acc_1", date: "2026-05-04", amount: "-680",
          raw_description: "KEPLER", source_id: "v1id-aaaa"
        )
        b = Canonical.transaction_id(
          account_id: "acc_1", date: "2026-05-05", amount: "-681",
          raw_description: "KEPLER CORRECTED", source_id: "v1id-aaaa"
        )
        assert_equal a, b
      end

      def test_transaction_id_handles_missing_date
        assert_match(/\Atxn_[0-9a-f]{16}\z/,
                     Canonical.transaction_id(account_id: "a", date: nil,
                                              amount: "1", raw_description: "x"))
      end

      def test_account_id_portable_ref_collides_across_institutions
        # The cross-provider matching contract: same physical account
        # scraped via two different providers (e.g. ING direct + Fintonic
        # aggregator) produces the same acc_<hex>. The institution
        # argument MUST NOT enter the digest when portable_ref is set.
        ing      = Canonical.account_id(institution: "ing",      portable_ref: "9999:0001")
        fintonic = Canonical.account_id(institution: "fintonic", portable_ref: "9999:0001")
        assert_equal ing, fintonic
        assert_match(/\Aacc_[0-9a-f]{16}\z/, ing)
      end

      def test_account_id_portable_ref_distinguishes_distinct_accounts
        a = Canonical.account_id(institution: "ing", portable_ref: "9999:0001")
        b = Canonical.account_id(institution: "ing", portable_ref: "1465:9999")
        refute_equal a, b
      end

      def test_account_id_portable_ref_strips_whitespace
        a = Canonical.account_id(institution: "ing", portable_ref: "9999:0001")
        b = Canonical.account_id(institution: "ing", portable_ref: "  9999:0001  ")
        assert_equal a, b
      end

      def test_account_id_portable_ref_overrides_other_refs
        # When portable_ref is present, fallback inputs (iban, source_id,
        # name, stable_ref) are completely ignored — that's what makes the
        # cross-provider collision deterministic, even when the two
        # providers expose different source_ids/names for the same account.
        with_portable = Canonical.account_id(
          institution: "ing", portable_ref: "9999:0001",
          iban: "ES0000000000000000000000", source_id: "ing-uuid", name: "Cuenta Naranja"
        )
        portable_only = Canonical.account_id(institution: "x", portable_ref: "9999:0001")
        assert_equal with_portable, portable_only
      end

      def test_account_id_falls_back_to_legacy_derivation_when_portable_ref_blank
        # Back-compat: accounts that can't produce a portable_ref (cash,
        # brokerage, aggregator-only banks with opaque product_ids) keep
        # the original (institution, ref) hash they had before this change.
        legacy = Canonical.account_id(institution: "fintonic", source_id: "abc123")
        [nil, "", "   "].each do |blank|
          assert_equal legacy,
                       Canonical.account_id(
                         institution: "fintonic", portable_ref: blank, source_id: "abc123"
                       )
        end
      end

      def test_account_id_raises_when_portable_ref_blank_and_no_fallback
        assert_raises(UnstableIdError) do
          Canonical.account_id(institution: "ing", portable_ref: "   ")
        end
      end

      def test_account_id_prefers_iban_over_source_id
        id_iban = Canonical.account_id(institution: "bbva", iban: "ES1", source_id: "X")
        id_srcid = Canonical.account_id(institution: "bbva", source_id: "X")
        refute_equal id_iban, id_srcid
      end

      def test_account_id_stable_ref_wins_over_iban
        id_ref = Canonical.account_id(institution: "bbva", iban: "ES1", stable_ref: "R")
        id_iban = Canonical.account_id(institution: "bbva", iban: "ES1")
        refute_equal id_ref, id_iban
      end

      def test_account_id_raises_when_all_refs_missing
        assert_raises(UnstableIdError) do
          Canonical.account_id(institution: "bbva")
        end
      end

      def test_account_id_treats_blank_strings_as_missing
        assert_raises(UnstableIdError) do
          Canonical.account_id(institution: "bbva", iban: "   ", name: "")
        end
      end

      def test_account_id_is_prefixed_and_16_hex
        id = Canonical.account_id(institution: "bbva", iban: "ES1")
        assert_match(/\Aacc_[0-9a-f]{16}\z/, id)
      end

      def test_liability_id_prefixed
        id = Canonical.liability_id(account_id: "acc_1", type: "credit_card")
        assert_match(/\Aliab_[0-9a-f]{16}\z/, id)
      end

      def test_liability_id_sub_ref_disambiguates
        a = Canonical.liability_id(account_id: "acc_1", type: "credit_card")
        b = Canonical.liability_id(account_id: "acc_1", type: "credit_card", sub_ref: "2")
        refute_equal a, b
      end

      def test_investment_id_prefixed
        id = Canonical.investment_id(account_id: "acc_1", symbol: "AAPL")
        assert_match(/\Ainv_[0-9a-f]{16}\z/, id)
      end
    end
  end
end
