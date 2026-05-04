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
      # explicitly so they can choose conventions like "bank:1465:1272"
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
