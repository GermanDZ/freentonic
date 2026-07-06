# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "bigdecimal"

module Freentonic
  # Runtime semantics of Normalizers::Plan: seeded scope, offline
  # interpretation (fetch guarded), entity assembly into a
  # CanonicalPayload with config.yml's scraper_version.
  class NormalizersPlanTest < Minitest::Test
    CONFIG = {
      institution: "testbank",
      scraper_version: "testbank/9.9",
      status_map: { "OK" => "posted" }
    }.freeze

    def normalize(plan, raw, config: CONFIG)
      Normalizers::Plan.new(plan, config: config,
                            stdout: StringIO.new, stderr: StringIO.new)
                       .call(raw)
    end

    def account_plan
      {
        "steps" => [
          { "select" => { "from" => "raw", "path" => "products", "default" => [] },
            "as" => "products" },
          { "for_each" => { "source" => "products" }, "as_item" => "p", "as" => "results",
            "do" => [
              { "select" => { "from" => "p", "path" => "id" }, "as" => "pid" },
              { "skip_when" => { "pid" => { "absent" => true } } },
              { "apply" => "join", "args" => { "parts" => ["prod:", "{pid}"] },
                "as" => "source_id" },
              { "apply" => "cents", "args" => { "amount" => "{p.balance}", "already_minor" => true },
                "as" => "balance_cents" },
              { "apply" => "cents_to_amount", "args" => { "cents" => "{balance_cents}" },
                "as" => "balance_amount" },
              { "apply" => "build_account",
                "args" => { "institution" => "{config.institution}", "source_id" => "{source_id}",
                            "currency" => "EUR", "name" => "{p.name}", "type" => "checking",
                            "balance" => { "current" => "{balance_amount}", "timestamp" => nil } },
                "as" => "account" },
              { "select" => { "from" => "p", "path" => "txs", "default" => [] },
                "as" => "txs_list" },
              { "for_each" => { "source" => "txs_list" }, "as_item" => "tx", "as" => "txns",
                "do" => [
                  { "apply" => "map_status",
                    "args" => { "value" => "{tx.state}", "mapping" => "{config.status_map}" },
                    "as" => "status" },
                  { "apply" => "build_transaction",
                    "args" => { "account_id" => "{account.id}", "amount" => 1,
                                "currency" => "EUR", "source_id" => "{tx.id}",
                                "status" => "{status}" },
                    "as" => "txn" },
                  { "yield" => "{txn}" }
                ] },
              { "yield" => { "account" => "{account}", "txns" => "{txns}" } }
            ] },
          { "apply" => "pluck", "args" => { "list" => "{results}", "key" => "account" },
            "as" => "accounts" },
          { "apply" => "pluck", "args" => { "list" => "{results}", "key" => "txns" },
            "as" => "txn_groups" },
          { "apply" => "flatten", "args" => { "list" => "{txn_groups}" },
            "as" => "transactions" }
        ],
        "output" => { "accounts" => "{accounts}", "transactions" => "{transactions}" }
      }
    end

    def test_builds_canonical_payload_with_scraper_version
      raw = { "products" => [
        { "id" => "p1", "name" => "Main", "balance" => 12_345,
          "txs" => [{ "id" => "t1", "state" => "OK" }] },
        { "name" => "no id — skipped" }
      ] }
      payload = normalize(account_plan, raw)

      assert_kind_of Canonical::CanonicalPayload, payload
      assert_equal "testbank/9.9", payload.meta["scraper_version"]
      assert_equal 1, payload.accounts.size

      acct = payload.accounts.first
      assert_equal "prod:p1", acct.source_id
      assert_equal "testbank", acct.institution
      assert_equal BigDecimal("123.45"), acct.balance.current

      assert_equal 1, payload.transactions.size
      txn = payload.transactions.first
      assert_equal acct.id, txn.account_id, "entity dig {account.id} must chain builders"
      assert_equal "posted", txn.status
    end

    def test_missing_nested_collections_produce_empty_lists
      raw = { "products" => [{ "id" => "p1", "name" => "Main", "balance" => 0 }] }
      payload = normalize(account_plan, raw)
      assert_equal 1, payload.accounts.size
      assert_empty payload.transactions
    end

    def test_liabilities_default_empty_and_bindable
      plan = {
        "steps" => [
          { "let" => "accounts", "value" => [] },
          { "let" => "transactions", "value" => [] }
        ],
        "output" => { "accounts" => "{accounts}", "transactions" => "{transactions}" }
      }
      payload = normalize(plan, {})
      assert_empty payload.liabilities
    end

    def test_fetch_in_a_normalize_plan_raises_offline_error
      plan = {
        "steps" => [{ "fetch" => "anything", "as" => "x" }],
        "output" => { "accounts" => "{x}", "transactions" => "{x}" }
      }
      err = assert_raises(UserError) { normalize(plan, {}) }
      assert_includes err.message, "normalize plans are offline"
    end

    def test_index_by_where_presence_matcher_finds_first_element_with_field
      plan = {
        "steps" => [
          { "select" => { "from" => "raw", "path" => "bank_details", "default" => [] },
            "as" => "bank_details" },
          { "index_by" => {
              "from" => "bank_details", "key" => "currency",
              "value" => { "path" => "details.accounts",
                           "where" => { "iban" => { "present" => true } },
                           "pick" => "iban" }
            }, "as" => "iban_by_currency" },
          { "lookup" => { "from" => "iban_by_currency", "key" => "EUR" }, "as" => "iban" },
          { "apply" => "build_account",
            "args" => { "institution" => "t", "source_id" => "s1", "currency" => "EUR",
                        "metadata" => { "parent_iban" => "{iban}" } },
            "as" => "account" },
          { "let" => "accounts", "value" => ["{account}"] },
          { "let" => "transactions", "value" => [] }
        ],
        "output" => { "accounts" => "{accounts}", "transactions" => "{transactions}" }
      }
      raw = { "bank_details" => [
        { "currency" => "EUR",
          "details" => { "accounts" => [{ "bic" => "X" }, { "iban" => "LT00 1234" }] } }
      ] }
      payload = normalize(plan, raw)
      assert_equal "LT00 1234", payload.accounts.first.metadata["parent_iban"]
    end

    def test_nil_config_tolerated
      plan = {
        "steps" => [
          { "let" => "accounts", "value" => [] },
          { "let" => "transactions", "value" => [] }
        ],
        "output" => { "accounts" => "{accounts}", "transactions" => "{transactions}" }
      }
      payload = Normalizers::Plan.new(plan, config: nil,
                                      stdout: StringIO.new, stderr: StringIO.new).call({})
      assert_nil payload.meta["scraper_version"]
    end
  end
end
