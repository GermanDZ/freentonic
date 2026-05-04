# frozen_string_literal: true

require "digest"
require "bigdecimal"
require "date"

module Freentonic
  module Canonical
    # Raised when a deterministic-ID helper cannot produce a stable ID from
    # the inputs given (e.g., an account with no IBAN, no source_id, and no
    # name). The caller must pass a stable_ref: override or accept that the
    # record is inherently non-stable — we refuse to silently generate
    # drifting IDs.
    class UnstableIdError < UserError; end

    # ASCII unit separator — impossible to appear in raw bank text, so no
    # escaping ambiguity when joining hash components.
    UNIT_SEPARATOR = "\x1f"

    # txn_<16 hex>. When source_id is non-blank, hash (account_id, source_id);
    # otherwise hash (account_id, date, amount, raw_description). Mirrors how
    # Canonical.account_id prefers iban/source_id over name.
    #
    # Without the source_id branch, two distinct upstream transactions sharing
    # the same (date, amount, description) on the same account collapse to
    # one id and SimpleFIN clients dedup the duplicates away (real bug seen
    # with ING Kepler debits on 2026-05-04).
    def self.transaction_id(account_id:, date:, amount:, raw_description:,
                            source_id: nil)
      sid = source_id.to_s.strip
      unless sid.empty?
        return Ids.digest("txn_", [account_id.to_s, sid])
      end

      components = [
        account_id.to_s,
        Ids.date_component(date),
        Ids.amount_component(amount),
        raw_description.to_s.strip
      ]
      Ids.digest("txn_", components)
    end

    # acc_<16 hex>.
    #
    # When portable_ref is non-blank, it is the *only* input to the digest
    # — institution is intentionally excluded so two providers scraping the
    # same physical account (e.g. ING via direct provider and Fintonic via
    # aggregator) collide on the same acc_<hex>. The portable_ref is a
    # provider-agnostic key derived from the account itself; for Spanish
    # banks the convention is "BANKID:PRODUCTID" — the 4-digit CCC bank
    # code and the last 4 digits of the account number. Both can be lifted
    # from an IBAN (positions 5–8 and the trailing 4 of the BBAN) or read
    # directly from aggregator payloads that already split them out.
    #
    # When portable_ref is absent, falls back to (institution, ref) where
    # ref is the first non-empty of stable_ref, iban, source_id, name.
    # Used for accounts where no portable key exists — cash, brokerage,
    # aggregator-only banks whose product_ids are opaque hashes.
    #
    # Raises UnstableIdError if neither portable_ref nor any fallback ref
    # is usable.
    def self.account_id(institution:, portable_ref: nil, iban: nil,
                        source_id: nil, name: nil, stable_ref: nil)
      portable = portable_ref.to_s.strip if portable_ref
      if portable && !portable.empty?
        return Ids.digest("acc_", [portable])
      end

      ref = [stable_ref, iban, source_id, name]
        .map { |v| v.to_s.strip if v }
        .find { |v| v && !v.empty? }

      if ref.nil?
        raise UnstableIdError,
              "Canonical.account_id(institution: #{institution.inspect}) " \
              "needs at least one of portable_ref:, iban:, source_id:, name:, " \
              "or stable_ref: to produce a stable ID"
      end

      Ids.digest("acc_", [institution.to_s, ref])
    end

    # liab_<16 hex>. account_id is the canonical account ID this liability
    # attaches to (may be nil if unattached). sub_ref disambiguates multiple
    # liabilities of the same type on the same account.
    def self.liability_id(account_id:, type:, sub_ref: nil)
      Ids.digest("liab_", [account_id.to_s, type.to_s, sub_ref.to_s])
    end

    # inv_<16 hex>.
    def self.investment_id(account_id:, symbol:)
      Ids.digest("inv_", [account_id.to_s, symbol.to_s])
    end

    # Helpers. Scoped under Ids to keep the public Canonical namespace clean
    # while leaving them reachable for testing.
    module Ids
      module_function

      def digest(prefix, components)
        prefix + Digest::SHA256.hexdigest(components.join(UNIT_SEPARATOR))[0, 16]
      end

      def date_component(date)
        case date
        when nil    then ""
        when Date   then date.iso8601
        when String then date
        else date.to_s
        end
      end

      def amount_component(amount)
        case amount
        when nil        then ""
        when BigDecimal then amount.to_s("F")
        when Numeric    then BigDecimal(amount.to_s).to_s("F")
        when String
          s = amount.strip
          s.empty? ? "" : BigDecimal(s).to_s("F")
        else amount.to_s
        end
      end
    end
  end
end
