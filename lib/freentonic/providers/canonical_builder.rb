# frozen_string_literal: true

require "bigdecimal"
require "freentonic"

module Freentonic
  module Providers
    # Shared construction logic for canonical-shaped provider normalizers.
    #
    # Every provider emits the same four entity kinds (Account, Transaction,
    # Liability, and the outer CanonicalPayload). This module centralizes
    # the boilerplate so per-provider normalizers only describe what's
    # actually provider-specific: field mapping.
    #
    # Module-function style: pure factories, no state. Each factory returns
    # a frozen Freentonic::Canonical entity value object.
    module CanonicalBuilder
      module_function

      # --- Value coercions -------------------------------------------------

      # Integer cents → BigDecimal major units. nil-safe.
      # Avoids Float because cents/100.0 drifts at edges (e.g., 0.1 + 0.2).
      def cents_to_amount(cents)
        return nil if cents.nil?
        BigDecimal(cents.to_s) / 100
      end

      # Legacy "settled"/"pending"/nil → canonical "posted"/"pending"/nil.
      def map_status(old_pending_status)
        case old_pending_status
        when "settled" then Freentonic::Canonical::Transaction::POSTED
        when "pending" then Freentonic::Canonical::Transaction::PENDING
        else old_pending_status
        end
      end

      # Resolve a provider-side status code through a declared mapping.
      # `mapping` is a plain Hash loaded from <provider>/config.yml's
      # `status_map:` block (auto-bound as STATUS_MAP via Configurable):
      #
      #   status_map:
      #     COMPLETED: posted
      #     PENDING:   pending
      #     DECLINED:  declined
      #
      # `posted` and `pending` resolve to the canonical constants
      # (Transaction::POSTED, Transaction::PENDING); any other string
      # passes through verbatim so providers can declare custom
      # downstream-only statuses ("declined", "reverted", …).
      #
      # Returns nil when raw is nil/blank or the mapping doesn't cover
      # it — callers decide whether to default to POSTED or leave
      # unset. Lookup is case-insensitive on the raw key so a provider
      # whose API mixes "Completed"/"COMPLETED" doesn't need two rows.
      def map_status_from(raw, mapping)
        return nil if raw.nil? || mapping.nil?
        key = raw.to_s
        return nil if key.empty?
        canonical =
          mapping[key] ||
            mapping[key.upcase] ||
            mapping[key.downcase] ||
            mapping.find { |k, _| k.to_s.casecmp(key).zero? }&.last
        return nil if canonical.nil?
        case canonical.to_s
        when "posted"  then Freentonic::Canonical::Transaction::POSTED
        when "pending" then Freentonic::Canonical::Transaction::PENDING
        else canonical.to_s
        end
      end

      # --- Portable keys ---------------------------------------------------

      # Cross-provider portable key for a Spanish-IBAN-bearing account.
      # The 4-digit tail of the IBAN identifies the account within a
      # bank, and a bank_code prefix scopes it across banks — together
      # they form the "BANKID:LAST4" shape that aggregators (Fintonic)
      # and direct scrapes (ING, Unicaja, …) can both produce, so
      # cross-source matching collapses onto the same canonical
      # Account.id. Returns [nil, nil] for non-Spanish or malformed
      # IBANs; the caller (or the framework's Canonical.account_id
      # default) falls back to (institution, source_id) derivation.
      #
      #   Builder.spanish_iban_portable_keys("ES0012345678901234567890",
      #                                      bank_code: "1465")
      #   #=> ["1465:7890", "bank:1465:7890"]
      def spanish_iban_portable_keys(iban, bank_code:)
        return [nil, nil] if bank_code.nil? || bank_code.to_s.empty?
        return [nil, nil] unless iban.is_a?(String) && iban.length >= 18 && iban.start_with?("ES")
        ref = "#{bank_code}:#{iban[-4, 4]}"
        [ref, "bank:#{ref}"]
      end

      # Cross-provider portable key for a credit-card account. The PAN's
      # last 4 digits identify the plastic; a bank_code prefix scopes
      # it across banks. PAN extraction defers to Helpers.pan_last4 so
      # masked/spaced/dashed PANs all resolve to the same 4-digit tail.
      # Returns [nil, nil] when the PAN is missing, blank, or has fewer
      # than 4 digits.
      #
      #   Builder.card_pan_portable_keys("**** **** **** 8619", bank_code: "1465")
      #   #=> ["1465:8619", "card:1465:8619"]
      def card_pan_portable_keys(pan, bank_code:)
        return [nil, nil] if bank_code.nil? || bank_code.to_s.empty?
        last4 = Freentonic::Providers::Helpers.pan_last4(pan)
        return [nil, nil] unless last4
        ref = "#{bank_code}:#{last4}"
        [ref, "card:#{ref}"]
      end

      # --- Entity factories ------------------------------------------------

      # Build a Canonical::Account. Computes id via Canonical.account_id.
      #
      # portable_ref, when supplied, makes the account id provider-agnostic
      # — see Canonical.account_id for the cross-provider matching contract.
      # Normalizers should set it whenever they can derive a stable per-
      # account key (e.g. "BANKID:PRODUCTID" for Spanish banks lifted from
      # the IBAN or split out by an aggregator).
      #
      # portable_id is the human-readable companion to portable_ref. The
      # framework does not derive one from the other — providers pass both
      # explicitly so they can choose conventions like "bank:9999:0001"
      # without coupling the digest input to the display string.
      def build_account(institution:, source_id:, currency:,
                        name: nil, type: nil, iban: nil, balance: nil,
                        metadata: {}, portable_ref: nil, portable_id: nil)
        id = Freentonic::Canonical.account_id(
          institution:  institution,
          portable_ref: portable_ref,
          iban:         iban,
          source_id:    source_id,
          name:         name
        )
        Freentonic::Canonical::Account.new(
          id:          id,
          source_id:   source_id,
          institution: institution,
          name:        name,
          type:        type,
          currency:    currency,
          iban:        iban,
          balance:     balance,
          metadata:    metadata || {},
          portable_id: portable_id
        )
      end

      # Build a Canonical::Transaction. Computes id via Canonical.transaction_id.
      # If raw_description is nil, falls back to description for id stability —
      # the cleaned description is at least as stable as "nothing".
      def build_transaction(account_id:, amount:, currency:,
                            source_id: nil, date: nil, value_date: nil,
                            description: nil, raw_description: nil,
                            status: nil, merchant: nil, category: nil,
                            metadata: {})
        id = Freentonic::Canonical.transaction_id(
          account_id:      account_id,
          date:            date,
          amount:          amount,
          raw_description: raw_description || description,
          source_id:       source_id
        )
        Freentonic::Canonical::Transaction.new(
          id:              id,
          source_id:       source_id,
          account_id:      account_id,
          amount:          amount,
          currency:        currency,
          date:            date,
          value_date:      value_date,
          description:     description,
          raw_description: raw_description,
          status:          status,
          merchant:        merchant,
          category:        category,
          metadata:        metadata || {}
        )
      end

      # Build a Canonical::Liability attached to a canonical Account.id.
      # sub_ref disambiguates multiple liabilities of the same type on the
      # same account (not common, but required by Canonical.liability_id).
      def build_liability(account_id:, type:, currency:,
                          source_id: nil, balance: nil, limit: nil,
                          due_date: nil, metadata: {}, sub_ref: nil)
        id = Freentonic::Canonical.liability_id(
          account_id: account_id,
          type:       type,
          sub_ref:    sub_ref
        )
        Freentonic::Canonical::Liability.new(
          id:         id,
          source_id:  source_id,
          type:       type,
          account_id: account_id,
          balance:    balance,
          limit:      limit,
          currency:   currency,
          due_date:   due_date,
          metadata:   metadata || {}
        )
      end

      # Wrap entity arrays into the outer envelope with a conventional
      # meta.scraper_version. Callers who need more meta keys can build
      # the payload directly via Freentonic::Canonical::CanonicalPayload.new.
      def payload(accounts:, transactions:, liabilities: [], scraper_version:)
        Freentonic::Canonical::CanonicalPayload.new(
          accounts:     accounts,
          transactions: transactions,
          liabilities:  liabilities,
          meta:         { "scraper_version" => scraper_version }
        )
      end
    end
  end
end
