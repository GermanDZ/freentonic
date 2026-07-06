# frozen_string_literal: true

require "date"
require "bigdecimal"
require_relative "../providers/helpers"
require_relative "../providers/canonical_builder"

module Freentonic
  module Fn
    # Tier A builtins: registrations over the already-tested
    # Providers::Helpers / Providers::CanonicalBuilder logic, so plans can
    # call them via `apply:`. Behavioral tests live with the wrapped code
    # (helpers_test.rb, canonical_builder_test.rb); the examples here are
    # the purity-harness contract, not exhaustive coverage.
    #
    # HELPERS carries the instance-method helpers without dragging in a
    # normalizer class; `pick` takes `aliases:` explicitly (a plan passes
    # `{config.field_aliases}`) rather than reading a class constant.
    HELPERS = Object.new.extend(Freentonic::Providers::Helpers)
    BUILDER = Freentonic::Providers::CanonicalBuilder

    define "cents" do |f|
      f.description "Amount in major units / minor units / Hash / comma-decimal String → integer cents."
      f.param :amount
      f.param :already_minor, :boolean, default: false
      f.example args: { "amount" => 12.34 }, returns: 1234
      f.example args: { "amount" => 1234, "already_minor" => true }, returns: 1234
      f.example args: { "amount" => "12,34" }, returns: 1234
      f.example args: { "amount" => nil }, returns: nil
      f.impl { |amount:, already_minor:| HELPERS.cents(amount, already_minor: already_minor) }
    end

    define "cents_to_amount" do |f|
      f.description "Integer cents → BigDecimal major units (nil-safe)."
      f.param :cents
      f.example args: { "cents" => 1234 }, returns: BigDecimal("12.34")
      f.example args: { "cents" => nil }, returns: nil
      f.impl { |cents:| BUILDER.cents_to_amount(cents) }
    end

    define "parse_date" do |f|
      f.description "Provider date value (ISO / DD-MM-YYYY / Unix) → Date, trying formats: first."
      f.param :value
      f.param :formats, :array
      f.example args: { "value" => "2024-03-15" }, returns: Date.new(2024, 3, 15)
      f.example args: { "value" => "05/06/2024", "formats" => ["%d/%m/%Y"] },
                returns: Date.new(2024, 6, 5)
      f.example args: { "value" => nil }, returns: nil
      f.impl { |value:, formats:| HELPERS.parse_date(value, preferred_formats: formats) }
    end

    define "parse_timestamp_ms" do |f|
      f.description "Timestamp value (ISO string / seconds / ms) → Unix milliseconds."
      f.param :value
      f.example args: { "value" => "2024-03-15T12:00:00.000Z" }, returns: 1_710_504_000_000
      f.impl { |value:| HELPERS.parse_timestamp_ms(value) }
    end

    define "map_status" do |f|
      f.description "Provider status code → canonical status via a status_map (case-insensitive)."
      f.param :value
      f.param :mapping, :hash
      f.example args: { "value" => "COMPLETED", "mapping" => { "COMPLETED" => "posted" } },
                returns: "posted"
      f.example args: { "value" => "Pending", "mapping" => { "PENDING" => "pending" } },
                returns: "pending"
      f.example args: { "value" => nil, "mapping" => { "COMPLETED" => "posted" } }, returns: nil
      f.impl { |value:, mapping:| BUILDER.map_status_from(value, mapping) }
    end

    define "pick" do |f|
      f.description "First non-nil value in source for the alias chain of a logical field key."
      f.param :key, :string, required: true
      f.param :source
      f.param :aliases, :hash, required: true
      f.example args: { "key" => "date",
                        "source" => { "fechavalor" => "01/02/2024" },
                        "aliases" => { "date" => %w[fechaoper fechavalor] } },
                returns: "01/02/2024"
      f.impl { |key:, source:, aliases:| HELPERS.pick(key, source, aliases: aliases) }
    end

    define "extract_fields" do |f|
      f.description "Pluck/rename fields from a Hash per a mapping of out_key => path | [fallback paths]."
      f.param :source
      f.param :mapping, :hash, required: true
      f.example args: { "source" => { "a" => { "b" => 1 }, "x" => 2 },
                        "mapping" => { "nested" => "a.b", "flat" => %w[missing x], "gone" => "nope" } },
                returns: { "nested" => 1, "flat" => 2, "gone" => nil }
      f.impl { |source:, mapping:| HELPERS.extract_fields(source, mapping) }
    end

    define "first_present" do |f|
      f.description "First candidate that is a non-empty stripped string; nil when none qualify."
      f.param :candidates, :array, required: true
      f.example args: { "candidates" => [nil, "  ", "Cuenta Naranja", "ING"] },
                returns: "Cuenta Naranja"
      f.example args: { "candidates" => [nil, ""] }, returns: nil
      f.impl { |candidates:| HELPERS.first_present(*candidates) }
    end

    define "pan_last4" do |f|
      f.description "Last 4 digits of a (possibly masked) card number; nil when fewer than 4 digits."
      f.param :value
      f.example args: { "value" => "**** **** **** 8619" }, returns: "8619"
      f.example args: { "value" => "****" }, returns: nil
      f.impl { |value:| Freentonic::Providers::Helpers.pan_last4(value) }
    end

    define "compact_whitespace" do |f|
      f.description "Collapse whitespace runs to single spaces and strip; nil passes through."
      f.param :value
      f.example args: { "value" => "  Recibo   ESCUELA \n KEPLER " }, returns: "Recibo ESCUELA KEPLER"
      f.example args: { "value" => nil }, returns: nil
      f.impl { |value:| value.nil? ? nil : value.to_s.gsub(/\s+/, " ").strip }
    end

    define "spanish_iban_portable_keys" do |f|
      f.description "Spanish IBAN → [portable_ref, portable_id] (\"BANK:LAST4\", \"bank:BANK:LAST4\"); [nil, nil] otherwise."
      f.param :iban
      f.param :bank_code, required: true
      f.example args: { "iban" => "ES0012345678901234567890", "bank_code" => "1465" },
                returns: ["1465:7890", "bank:1465:7890"]
      f.example args: { "iban" => nil, "bank_code" => "1465" }, returns: [nil, nil]
      f.impl { |iban:, bank_code:| BUILDER.spanish_iban_portable_keys(iban, bank_code: bank_code) }
    end

    define "card_pan_portable_keys" do |f|
      f.description "Card PAN (masked ok) → [portable_ref, portable_id] (\"BANK:LAST4\", \"card:BANK:LAST4\"); [nil, nil] otherwise."
      f.param :pan
      f.param :bank_code, required: true
      f.example args: { "pan" => "**** **** **** 8619", "bank_code" => "1465" },
                returns: ["1465:8619", "card:1465:8619"]
      f.example args: { "pan" => "***", "bank_code" => "1465" }, returns: [nil, nil]
      f.impl { |pan:, bank_code:| BUILDER.card_pan_portable_keys(pan, bank_code: bank_code) }
    end

    define "compact" do |f|
      f.description "Hash minus nil-valued entries — the declarative `.compact`."
      f.param :hash, :hash, required: true
      f.example args: { "hash" => { "a" => 1, "b" => nil, "c" => false } },
                returns: { "a" => 1, "c" => false }
      f.impl { |hash:| hash.reject { |_, v| v.nil? } }
    end

    define "flatten" do |f|
      f.description "Flatten one level of nesting in a list (nil-safe)."
      f.param :list, :array, required: true
      f.example args: { "list" => [[1, 2], [], [3]] }, returns: [1, 2, 3]
      f.impl { |list:| Array(list).flatten(1) }
    end

    define "pluck" do |f|
      f.description "Extract one field from each Hash in a list; non-Hash rows yield nil unless compact:."
      f.param :list, :array, required: true
      f.param :key, :string, required: true
      f.param :compact, :boolean, default: false
      f.example args: { "list" => [{ "a" => 1 }, { "a" => nil }, "junk"], "key" => "a" },
                returns: [1, nil, nil]
      f.example args: { "list" => [{ "a" => 1 }, { "b" => 2 }], "key" => "a", "compact" => true },
                returns: [1]
      f.impl do |list:, key:, compact:|
        values = Array(list).map { |el| el.is_a?(Hash) ? el[key] : nil }
        compact ? values.compact : values
      end
    end

    define "join" do |f|
      f.description "Join parts into one string — the whole-token-safe form of string " \
                    "interpolation. nil parts drop; drop_empty: also drops blank parts."
      f.param :parts, :array, required: true
      f.param :separator, :string, default: ""
      f.param :drop_empty, :boolean, default: false
      f.example args: { "parts" => ["pocket:", "p-1"] }, returns: "pocket:p-1"
      f.example args: { "parts" => ["Recibo", nil, "  "], "separator" => " — ", "drop_empty" => true },
                returns: "Recibo"
      f.impl do |parts:, separator:, drop_empty:|
        kept = parts.compact.map(&:to_s)
        kept = kept.reject { |s| s.strip.empty? } if drop_empty
        kept.join(separator)
      end
    end

    define "strip" do |f|
      f.description "Leading/trailing whitespace strip with to_s coercion; nil → \"\" (matches `.to_s.strip`)."
      f.param :value
      f.example args: { "value" => "  Coffee  Shop " }, returns: "Coffee  Shop"
      f.example args: { "value" => nil }, returns: ""
      f.impl { |value:| value.to_s.strip }
    end

    define "build_account" do |f|
      f.description "Build a frozen Canonical::Account with a deterministic id."
      f.param :institution, :any, required: true
      f.param :source_id, :any, required: true
      f.param :currency, :string, required: true
      f.param :name, :string
      f.param :type, :string
      f.param :iban, :string
      f.param :balance, :hash
      f.param :metadata, :hash, default: {}
      f.param :portable_ref, :string
      f.param :portable_id, :string
      f.example args: { "institution" => "testbank", "source_id" => "pocket:1",
                        "currency" => "EUR", "name" => "Main", "type" => "checking" },
                matching: { source_id: "pocket:1", institution: "testbank",
                            currency: "EUR", name: "Main", type: "checking" }
      f.impl do |institution:, source_id:, currency:, name:, type:, iban:,
                 balance:, metadata:, portable_ref:, portable_id:|
        BUILDER.build_account(institution: institution, source_id: source_id,
                              currency: currency, name: name, type: type, iban: iban,
                              balance: balance, metadata: metadata,
                              portable_ref: portable_ref, portable_id: portable_id)
      end
    end

    define "build_transaction" do |f|
      f.description "Build a frozen Canonical::Transaction with a deterministic id."
      f.param :account_id, :string, required: true
      f.param :amount, :any, required: true
      f.param :currency, :string, required: true
      f.param :source_id
      f.param :date
      f.param :value_date
      f.param :description, :string
      f.param :raw_description, :string
      f.param :status, :string
      f.param :merchant, :hash
      f.param :category, :string
      f.param :metadata, :hash, default: {}
      f.example args: { "account_id" => "acc_0123456789abcdef", "amount" => BigDecimal("-15.17"),
                        "currency" => "EUR", "source_id" => "tx:1",
                        "date" => Date.new(2026, 1, 2), "description" => "Coffee" },
                matching: { account_id: "acc_0123456789abcdef", source_id: "tx:1",
                            currency: "EUR", description: "Coffee" }
      f.impl do |account_id:, amount:, currency:, source_id:, date:, value_date:,
                 description:, raw_description:, status:, merchant:, category:, metadata:|
        BUILDER.build_transaction(account_id: account_id, amount: amount, currency: currency,
                                  source_id: source_id, date: date, value_date: value_date,
                                  description: description, raw_description: raw_description,
                                  status: status, merchant: merchant, category: category,
                                  metadata: metadata)
      end
    end

    define "build_liability" do |f|
      f.description "Build a frozen Canonical::Liability attached to a canonical account id."
      f.param :account_id, :string, required: true
      f.param :type, :string, required: true
      f.param :currency, :string, required: true
      f.param :source_id
      f.param :balance
      f.param :limit
      f.param :due_date
      f.param :metadata, :hash, default: {}
      f.param :sub_ref, :string
      f.example args: { "account_id" => "acc_0123456789abcdef", "type" => "credit_card",
                        "currency" => "EUR", "source_id" => "card:9" },
                matching: { account_id: "acc_0123456789abcdef", type: "credit_card",
                            source_id: "card:9" }
      f.impl do |account_id:, type:, currency:, source_id:, balance:, limit:,
                 due_date:, metadata:, sub_ref:|
        BUILDER.build_liability(account_id: account_id, type: type, currency: currency,
                                source_id: source_id, balance: balance, limit: limit,
                                due_date: due_date, metadata: metadata, sub_ref: sub_ref)
      end
    end
  end
end
