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

      def test_transaction_id_handles_missing_date
        assert_match(/\Atxn_[0-9a-f]{16}\z/,
                     Canonical.transaction_id(account_id: "a", date: nil,
                                              amount: "1", raw_description: "x"))
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
