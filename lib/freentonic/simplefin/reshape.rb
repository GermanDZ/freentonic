# frozen_string_literal: true

require "openssl"
require "time"

module Freentonic
  module Simplefin
    # Converts freentonic's normalized provider payload shape into the
    # SimpleFIN wire envelope that Actual Budget's `src/app-simplefin`
    # adapter expects.
    #
    # Input shape (freentonic convention):
    #
    #   { "source_tag": "ing",
    #     "accounts": [
    #       { "external_id":   "123",
    #         "bank_name":     "ING",
    #         "currency":      "EUR",
    #         "balance_cents": 123456,
    #         "balance_at":    "2026-04-22T10:00:00Z",
    #         "movements": [
    #           { "dedup_key":    "bank-id",
    #             "amount_cents": -500,
    #             "date":         "2026-04-22",
    #             "description":  "Coffee",
    #             "payee":        "Starbucks" } ] } ] }
    #
    # Output (SimpleFIN):
    #
    #   { "errors": [],
    #     "accounts": [
    #       { "id":           "123",
    #         "org":          { "name" => "ING" },
    #         "currency":     "EUR",
    #         "balance":      "1234.56",
    #         "balance-date": 1713780000,
    #         "transactions": [
    #           { "id":          "bank-id",
    #             "posted":      1713730000,
    #             "amount":      "-5.00",
    #             "description": "Coffee",
    #             "payee":       "Starbucks" } ] } ] }
    module Reshape
      REQUIRED_ACCOUNT_FIELDS = %w[currency balance_date balance].freeze

      module_function

      # Convert a normalized payload into a SimpleFIN envelope. Returns a
      # Hash. Missing per-account fields (currency / balance date) are
      # surfaced via the `errors` array and the offending account is NOT
      # included in `accounts`.
      def call(normalized)
        envelope = { "accounts" => [], "errors" => [] }
        return envelope unless normalized.is_a?(Hash)

        # Top-level context feeds org.* fallbacks when the provider's
        # normalizer doesn't emit per-account bank metadata.
        context = {
          source_tag: (normalized["source_tag"] || "freentonic").to_s
        }

        accounts = Array(normalized["accounts"])
        accounts.each do |account|
          reshape_account(account, envelope, context)
        end
        envelope
      end

      # Filter transactions by the SimpleFIN query params (start-date,
      # end-date, pending). The caller is responsible for parsing the
      # raw query string; this takes an already-parsed Hash.
      def apply_query(envelope, params)
        return envelope unless envelope.is_a?(Hash) && envelope["accounts"].is_a?(Array)

        start_ts = params[:start_date] || params["start-date"]
        end_ts   = params[:end_date]   || params["end-date"]
        pending  = params[:pending]    || params["pending"]
        balances_only = params[:balances_only] || params["balances-only"]
        account_filter = Array(params[:account] || params["account"])

        start_ts = Integer(start_ts) rescue nil
        end_ts   = Integer(end_ts) rescue nil
        pending_allowed = truthy?(pending)

        accounts = envelope["accounts"].map do |account|
          next nil if account_filter.any? && !account_filter.include?(account["id"])
          reduced = account.dup
          txs = Array(account["transactions"])
          if balances_only && truthy?(balances_only)
            reduced["transactions"] = []
          else
            reduced["transactions"] = txs.select do |tx|
              posted = tx["posted"]
              next false unless posted.is_a?(Integer)
              next false if start_ts && posted < start_ts
              next false if end_ts   && posted > end_ts
              next false if tx["pending"] == true && !pending_allowed
              true
            end
          end
          reduced
        end.compact

        envelope.merge("accounts" => accounts)
      end

      # Deterministic 24-char transaction id synthesis. Callers should prefer
      # whatever stable id the normalizer already provides (dedup_key); this
      # kicks in only when the provider doesn't emit one.
      def stable_tx_id(account_id, movement)
        key = movement["dedup_key"] || movement[:dedup_key]
        return key if key.is_a?(String) && !key.empty?
        parts = [
          account_id,
          movement["posted"] || movement["date"] || movement["transacted_at"],
          movement["amount_cents"] || movement["amount"],
          (movement["description"] || "").to_s.strip.downcase
        ]
        OpenSSL::Digest::SHA256.hexdigest(parts.map(&:to_s).join("\x1F"))[0, 24]
      end

      # ── private helpers ─────────────────────────────────────

      def reshape_account(account, envelope, context = {})
        unless account.is_a?(Hash)
          envelope["errors"] << "simplefin: non-hash account in payload"
          return
        end

        account_id = account["external_id"] || account["id"]
        unless account_id.is_a?(String) && !account_id.empty?
          envelope["errors"] << "simplefin: account missing external_id"
          return
        end

        currency = (account["currency"] || account["currency_iso"]).to_s
        unless currency.match?(/\A[A-Z]{3}\z/)
          envelope["errors"] << "simplefin: account #{account_id} missing ISO 4217 currency"
          return
        end

        balance_cents = account["balance_cents"] || account["balance"]
        balance_str   = cents_to_decimal(balance_cents)
        if balance_str.nil?
          envelope["errors"] << "simplefin: account #{account_id} missing balance"
          return
        end

        # balance-date: prefer whatever the provider captured. If the
        # provider's API doesn't surface a balance timestamp (ING Spain is
        # one), fall back to "now" so Actual still ingests the account.
        # This is a timestamp-of-capture field, not a ledger value, so an
        # approximate value is strictly safer than dropping the account.
        balance_date = to_unix(account["balance_at"] || account["balance_date"]) || Time.now.to_i

        transactions = Array(account["movements"] || account["transactions"]).map do |mov|
          reshape_movement(account_id, mov)
        end.compact

        # SimpleFIN-compliant org block — Actual's CreateAccountModal reads
        # `org.domain`, `org.id`, `org.url`, not just `org.name`. Emit
        # sane fallbacks so the frontend doesn't crash on undefined
        # property access.
        bank_key  = (account["bank_key"] || context[:source_tag] || "freentonic").to_s
        org_name  = (account["bank_name"] || context[:source_tag] || bank_key).to_s
        org_domain = (account["bank_domain"] || "#{bank_key}.local").to_s
        org_url   = (account["bank_url"] || "about:blank").to_s

        account_name = (account["name"] || account["alias"] || account["product_number"] || account_id).to_s

        envelope["accounts"] << {
          "id"            => account_id,
          "name"          => account_name,
          "currency"      => currency,
          "balance"       => balance_str,
          "balance-date"  => balance_date,
          "available-balance" => available_balance(account),
          "org"           => {
            "name"     => org_name,
            "domain"   => org_domain,
            "sfin-url" => org_url,
            "url"      => org_url,
            "id"       => bank_key
          },
          "transactions"  => transactions,
          "extra"         => {}
        }.compact
      end

      def reshape_movement(account_id, movement)
        return nil unless movement.is_a?(Hash)

        amount_str = cents_to_decimal(movement["amount_cents"] || movement["amount"])
        return nil if amount_str.nil?

        posted = to_unix(movement["posted"] || movement["date"])
        return nil if posted.nil?

        tx = {
          "id"          => stable_tx_id(account_id, movement),
          "posted"      => posted,
          "amount"      => amount_str,
          "description" => (movement["description"] || movement["payee"] || "").to_s,
          "payee"       => (movement["payee"] || movement["description"] || "").to_s
        }
        if (transacted = to_unix(movement["transacted_at"] || movement["transacted"]))
          tx["transacted_at"] = transacted
        end
        tx["pending"] = true if movement["pending"] == true
        tx
      end

      # Produce a SimpleFIN-style decimal string from an integer cent value
      # (or a numeric/string that looks like one). Returns nil for nil or
      # unparseable inputs. Preserves sign.
      def cents_to_decimal(value)
        return nil if value.nil?
        if value.is_a?(String) && value.include?(".")
          # Already a decimal string; normalize sign + pad.
          return format("%.2f", Float(value))
        end
        cents = Integer(value)
        sign = cents.negative? ? "-" : ""
        abs  = cents.abs
        whole = abs / 100
        frac  = abs % 100
        "#{sign}#{whole}.#{frac.to_s.rjust(2, '0')}"
      rescue ArgumentError, TypeError
        nil
      end

      def to_unix(value)
        case value
        when nil
          nil
        when Integer
          value
        when String
          Time.parse(value).to_i
        when Time
          value.to_i
        else
          nil
        end
      rescue ArgumentError
        nil
      end

      def available_balance(account)
        available = account["available_balance_cents"] || account["available_balance"]
        cents_to_decimal(available)
      end

      def truthy?(value)
        return true  if value == true
        return false if value == false || value.nil?
        %w[1 true yes on].include?(value.to_s.downcase)
      end
    end
  end
end
