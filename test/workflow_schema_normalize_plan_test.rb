# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

module Freentonic
  # Static validation of `normalize: plan:` (Ask 8): the extract-plan step
  # grammar minus fetch:, seeded with raw/config/today, output restricted
  # to the entity-list contract.
  class WorkflowSchemaNormalizePlanTest < Minitest::Test
    def load_error(normalize_yaml)
      yaml = <<~YAML
        version: 1
        pipeline: []
        phases: {}
        #{normalize_yaml}
      YAML
      Dir.mktmpdir do |d|
        path = File.join(d, "workflow.yml")
        File.write(path, yaml)
        begin
          WorkflowSchema.load(path)
          nil
        rescue UserError => e
          e.message
        end
      end
    end

    MINIMAL_OUTPUT = <<~YAML
      output:
        accounts: "{accounts}"
        transactions: "{transactions}"
    YAML

    def test_valid_normalize_plan_loads_clean
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - select: { from: raw, path: pockets, default: [] }
                as: pockets
              - for_each: { source: pockets }
                as_item: pocket
                as: accounts
                do:
                  - apply: build_account
                    args:
                      institution: "{config.institution}"
                      source_id: "{pocket.id}"
                      currency: EUR
                    as: account
                  - yield: "{account}"
              - let: transactions
                value: []
            output:
              accounts: "{accounts}"
              transactions: "{transactions}"
      YAML
      assert_nil err
    end

    def test_plan_and_ruby_together_rejected
      err = load_error(<<~YAML)
        normalize:
          plan: { steps: [], output: { accounts: "{raw}", transactions: "{raw}" } }
          ruby: ./normalizer.rb
          class: Foo::Bar
      YAML
      assert_includes err, "declares both plan: and ruby:/class:"
    end

    def test_neither_plan_nor_ruby_rejected
      err = load_error(<<~YAML)
        normalize: {}
      YAML
      assert_includes err, "must declare plan: or ruby: and class:"
    end

    def test_ruby_class_form_still_loads
      err = load_error(<<~YAML)
        normalize:
          ruby: ./normalizer.rb
          class: Foo::Bar
      YAML
      assert_nil err
    end

    def test_fetch_rejected_in_normalize_plan
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
            #{MINIMAL_OUTPUT.gsub("\n", "\n            ")}
      YAML
      assert_includes err, "unknown step"
      refute_includes err.split("got keys").first, "fetch" # fetch absent from allowed list
    end

    def test_fetch_rejected_inside_normalize_for_each
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - select: { from: raw, path: rows }
                as: rows
              - for_each: { source: rows }
                as_item: row
                as: accounts
                do:
                  - fetch: fetch_wallet
                    as: extra
                  - yield: "{row}"
              - let: transactions
                value: []
            output:
              accounts: "{accounts}"
              transactions: "{transactions}"
      YAML
      assert_includes err, "unknown step"
    end

    def test_seeds_raw_config_today_are_bound
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - select: { from: raw, path: rows }
                as: accounts
              - apply: map_status
                args: { value: "x", mapping: "{config.status_map}" }
                as: status
              - let: transactions
                value: ["{today}"]
            output:
              accounts: "{accounts}"
              transactions: "{transactions}"
      YAML
      assert_nil err
    end

    def test_extract_seeds_not_available_in_normalize_plan
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - let: transactions
                value: "{from_ms}"
              - let: accounts
                value: []
            output:
              accounts: "{accounts}"
              transactions: "{transactions}"
      YAML
      assert_includes err, "unbound name"
      assert_includes err, "from_ms"
    end

    def test_output_requires_accounts_and_transactions
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - let: accounts
                value: []
            output:
              accounts: "{accounts}"
      YAML
      assert_includes err, "missing required key(s) transactions"
    end

    def test_output_rejects_unknown_keys
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - let: accounts
                value: []
              - let: transactions
                value: []
            output:
              accounts: "{accounts}"
              transactions: "{transactions}"
              meta: "{accounts}"
      YAML
      assert_includes err, "unknown key(s) meta"
    end

    def test_index_by_where_operator_matchers_validate
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - select: { from: raw, path: bank_details }
                as: bank_details
              - index_by:
                  from: bank_details
                  key: currency
                  value: { path: details.accounts, where: { iban: { present: true } }, pick: iban }
                as: iban_by_currency
              - let: accounts
                value: []
              - let: transactions
                value: []
            output:
              accounts: "{accounts}"
              transactions: "{transactions}"
      YAML
      assert_nil err
    end

    def test_index_by_where_unknown_operator_rejected
      err = load_error(<<~YAML)
        normalize:
          plan:
            steps:
              - select: { from: raw, path: bank_details }
                as: bank_details
              - index_by:
                  from: bank_details
                  key: currency
                  value: { path: details.accounts, where: { iban: { matches: ".*" } }, pick: iban }
                as: m
              - let: accounts
                value: []
              - let: transactions
                value: []
            output:
              accounts: "{accounts}"
              transactions: "{transactions}"
      YAML
      assert_includes err, "unknown operator \"matches\""
    end
  end
end
