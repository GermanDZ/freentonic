# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

module Freentonic
  # Static validation of the `apply:` verb (Ask 7) — load-time whitelist
  # checks against the Fn registry, mirroring how fetch: validates against
  # the declared-endpoint list.
  class WorkflowSchemaApplyTest < Minitest::Test
    def load_error(body_yaml)
      yaml = <<~YAML
        version: 1
        pipeline: []
        phases: {}
        api_client:
          base_url: https://api.example
          endpoints:
            - name: fetch_wallet
              method: GET
              path: /wallet
        #{body_yaml}
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

    def test_valid_apply_loads_clean
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - apply: cents
                args: { amount: "{wallet.balance}", already_minor: true }
                as: balance_cents
            output:
              balance_cents: "{balance_cents}"
      YAML
      assert_nil err
    end

    def test_unregistered_function_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - apply: no_such_fn
                as: x
            output: { x: "{x}" }
      YAML
      assert_includes err, '"no_such_fn" is not a registered function'
      assert_includes err, "cents"
    end

    def test_unknown_parameter_rejected_at_load
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - apply: pan_last4
                args: { value: "8619", nope: 1 }
                as: x
            output: { x: "{x}" }
      YAML
      assert_includes err, "unknown parameter(s) nope for pan_last4"
      assert_includes err, "params: value"
    end

    def test_missing_required_parameter_rejected_at_load
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - apply: pick
                args: { key: date }
                as: x
            output: { x: "{x}" }
      YAML
      assert_includes err, "missing required parameter(s)"
      assert_includes err, "pick"
    end

    def test_non_hash_args_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - apply: pan_last4
                args: "8619"
                as: x
            output: { x: "{x}" }
      YAML
      assert_includes err, "args: must be a hash"
    end

    def test_unbound_ref_in_args_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - apply: pan_last4
                args: { value: "{never_bound}" }
                as: x
            output: { x: "{x}" }
      YAML
      assert_includes err, "{never_bound}"
      assert_includes err, "unbound name"
    end

    def test_missing_as_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - apply: pan_last4
                args: { value: "8619" }
            output: {}
      YAML
      assert_includes err, "requires a non-empty as:"
    end

    def test_apply_binds_its_as_for_downstream_steps
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - apply: pan_last4
                args: { value: "8619" }
                as: last4
              - let: label
                value: "{last4}"
            output: { label: "{label}" }
      YAML
      assert_nil err
    end

    def test_apply_allowed_inside_for_each_do_block
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: rows
              - for_each:
                  source: rows
                as_item: row
                as: amounts
                do:
                  - apply: cents
                    args: { amount: "{row.amount}" }
                    as: amount_cents
                  - yield: "{amount_cents}"
            output: { amounts: "{amounts}" }
      YAML
      assert_nil err
    end

    def test_apply_allowed_in_elevate_steps
      err = load_error(<<~YAML)
        elevate:
          steps:
            - apply: compact_whitespace
              args: { value: "  a  b " }
              as: cleaned
            - note: "cleaned {cleaned}"
      YAML
      assert_nil err
    end

    def test_apply_with_when_gate_validates_gate_bindings
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - apply: pan_last4
                args: { value: "8619" }
                as: x
                when: { never_bound: { present: true } }
            output: { x: "{x}" }
      YAML
      assert_includes err, "not a bound name"
    end
  end
end
