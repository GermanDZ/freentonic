# frozen_string_literal: true

# Example normalizer for example_bank.yml.
#
# Normalizers convert the extractor's raw provider payload into a
# `Freentonic::Canonical::CanonicalPayload`, which is the universal
# internal shape every exporter and formatter consumes.
#
# Use the deterministic-ID helpers (Canonical.account_id /
# Canonical.transaction_id / etc.) so IDs stay stable across syncs and
# different workflow runs against the same source. Hand-rolling hashes
# means two runs of the same bank can produce different IDs — defeats
# the whole point.
#
# The factory keyword args are permissive: pass `nil` for any optional
# field you don't have. Required fields per entity are documented in
# docs/canonical-data-model.md.

module ExampleBank
  class Normalizer
    INSTITUTION = "example_bank"

    def call(raw, context: {})
      accounts = Array(raw["accounts"]).map { |a| build_account(a) }
      account_id_by_source = accounts.each_with_object({}) { |acct, h| h[acct.source_id] = acct.id }

      transactions = Array(raw["movements"]).flat_map do |source_ref, movements|
        canonical_account_id = account_id_by_source[source_ref.to_s]
        Array(movements).map { |m| build_transaction(m, canonical_account_id) }
      end

      Freentonic::Canonical::CanonicalPayload.new(
        accounts: accounts,
        transactions: transactions,
        meta: {
          "scraper_version" => "example_bank/0.1",
          "fetched_at" => raw["fetched_at"]
        }
      )
    end

    private

    def build_account(raw_account)
      source_id = (raw_account["ref"] || raw_account["id"]).to_s
      Freentonic::Canonical::Account.new(
        id: Freentonic::Canonical.account_id(
          institution: INSTITUTION,
          iban: raw_account["iban"],
          source_id: source_id
        ),
        source_id: source_id,
        institution: INSTITUTION,
        name: raw_account["alias"] || raw_account["name"],
        type: map_account_type(raw_account["product"]),
        currency: raw_account["currency"],
        iban: raw_account["iban"],
        balance: {
          current: raw_account["balance"],
          available: raw_account["available"],
          timestamp: raw_account["fetched_at"]
        }
      )
    end

    def build_transaction(raw_movement, canonical_account_id)
      Freentonic::Canonical::Transaction.new(
        id: Freentonic::Canonical.transaction_id(
          account_id: canonical_account_id,
          date: raw_movement["booking_date"],
          amount: raw_movement["amount"],
          raw_description: raw_movement["concept"]
        ),
        source_id: raw_movement["ref"],
        account_id: canonical_account_id,
        date: raw_movement["booking_date"],
        value_date: raw_movement["value_date"],
        amount: raw_movement["amount"],
        currency: raw_movement["currency"],
        description: clean_description(raw_movement["concept"]),
        raw_description: raw_movement["concept"],
        status: map_status(raw_movement["status"]),
        merchant: build_merchant(raw_movement),
        category: raw_movement["category"]
      )
    end

    def build_merchant(raw_movement)
      return nil unless raw_movement["merchant_name"]
      {
        name: raw_movement["merchant_name"],
        normalized: !raw_movement["merchant_name"].include?("*")
      }
    end

    def map_account_type(product)
      case product&.downcase
      when "checking", "current"          then "checking"
      when "savings"                      then "savings"
      when "credit_card", "card"          then "credit_card"
      when "investment", "brokerage"      then "investment"
      else product&.to_s
      end
    end

    def map_status(raw_status)
      case raw_status&.upcase
      when "BOOKED", "POSTED", "CLEARED" then "posted"
      when "PENDING", "AUTHORIZED"        then "pending"
      else raw_status&.downcase
      end
    end

    def clean_description(concept)
      return nil unless concept
      concept.split("*").first.to_s.strip.squeeze(" ")
    end
  end
end
