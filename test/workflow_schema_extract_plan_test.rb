# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

module Freentonic
  class WorkflowSchemaExtractPlanTest < Minitest::Test
    # Build a workflow YAML string with a given extract: block and a fixed
    # two-endpoint api_client, load it through the real schema, and return
    # the error message (or nil when it validates clean).
    def load_error(extract_yaml)
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
            - name: fetch_details
              method: GET
              path: /details
              params: { currency: "{currency}" }
        #{extract_yaml}
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

    # A well-formed plan mirroring the Revolut shape validates clean.
    def test_valid_plan_loads
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - select: { from: wallet, path: pockets }
                as: pockets
              - for_each:
                  source: pockets
                  pluck: currency
                  uniq: true
                  compact: true
                as_item: currency
                as: details
                do:
                  - fetch: fetch_details
                    args: { currency: "{currency}" }
                    as: detail
                    safe: true
                  - yield: { currency: "{currency}", detail: "{detail}" }
                    skip_if_nil: detail
            output:
              pockets: "{pockets}"
              details: "{details}"
      YAML
      assert_nil err
    end

    def test_both_forms_rejected
      err = load_error(<<~YAML)
        extract:
          plan: { steps: [], output: {} }
          ruby: ./x.rb
          class: X
      YAML
      assert_includes err, "declares both plan: and ruby:/class:"
    end

    def test_fetch_unknown_endpoint_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_nope
                as: x
            output: { x: "{x}" }
      YAML
      assert_includes err, "fetch_nope"
      assert_includes err, "not a declared api_client endpoint"
    end

    def test_unbound_reference_in_output_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
            output: { w: "{missing}" }
      YAML
      assert_includes err, "unbound name"
      assert_includes err, "missing"
    end

    def test_unbound_source_in_for_each_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - for_each: { source: nope }
                as_item: x
                as: out
                do:
                  - yield: "{x}"
            output: { out: "{out}" }
      YAML
      assert_includes err, "not bound by an earlier step"
    end

    def test_for_each_without_yield_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - for_each: { source: wallet }
                as_item: x
                as: out
                do:
                  - fetch: fetch_details
                    args: { currency: "{x}" }
                    as: d
            output: { out: "{out}" }
      YAML
      assert_includes err, "must contain a yield: step"
    end

    def test_collect_map_requires_key
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - for_each: { source: wallet }
                as_item: x
                as: out
                collect: map
                do:
                  - yield: "{x}"
            output: { out: "{out}" }
      YAML
      assert_includes err, "collect: map requires a key: template"
    end

    def test_unknown_verb_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - frobnicate: fetch_wallet
            output: {}
      YAML
      assert_includes err, "unknown step"
    end

    def test_yield_outside_for_each_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - yield: "{from_date}"
            output: {}
      YAML
      assert_includes err, "unknown step"
    end

    def test_seed_bindings_are_available
      # from_date / from_ms / now_ms are pre-seeded, so referencing them
      # without an earlier bind validates clean.
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_details
                args: { currency: "{from_ms}" }
                as: d
            output: { d: "{d}", when: "{from_date}" }
      YAML
      assert_nil err
    end

    def test_loop_var_not_visible_in_output
      # as_item is scoped to the do: block; referencing it in output is
      # an unbound-name error.
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - for_each: { source: wallet }
                as_item: item
                as: out
                do:
                  - yield: "{item}"
            output: { leaked: "{item}" }
      YAML
      assert_includes err, "unbound name"
      assert_includes err, "item"
    end

    # ── Phase-2 verbs: valid shapes load clean ─────────────────────────

    def test_valid_phase2_plan_loads
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - let: begin_date
                coalesce: ["{from_date}", "2015-01-01"]
              - let: cutoff
                days_ago: 30
              - let: cutoff2
                value: "{today}"
                when: { lookback_days: { gt: 30 } }
              - fetch: fetch_wallet
                as: wallet
              - select: { from: wallet, path: a }
                as: a
              - select: { from: wallet, path: b }
                as: b
              - concat: [a, b]
                as: merged
              - dedup_by: [numMovimiento, nummov]
                from: merged
                as: deduped
            output:
              begin_date: "{begin_date}"
              deduped: "{deduped}"
      YAML
      assert_nil err
    end

    def test_seed_bindings_today_and_lookback_days_available
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - let: c
                value: "{today}"
                when: { lookback_days: { gte: 0 } }
            output: { c: "{c}" }
      YAML
      assert_nil err
    end

    def test_let_requires_exactly_one_source
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - let: x
                value: "{from_date}"
                days_ago: 30
            output: { x: "{x}" }
      YAML
      assert_includes err, "exactly one of value:, coalesce:, days_ago:"
    end

    def test_let_coalesce_unbound_ref_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - let: x
                coalesce: ["{nope}"]
            output: { x: "{x}" }
      YAML
      assert_includes err, "unbound name"
    end

    def test_concat_unbound_name_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - concat: [wallet, missing]
                as: out
            output: { out: "{out}" }
      YAML
      assert_includes err, "not bound by an earlier step"
      assert_includes err, "missing"
    end

    def test_dedup_by_unbound_from_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - dedup_by: id
                from: nope
                as: out
            output: { out: "{out}" }
      YAML
      assert_includes err, "not bound by an earlier step"
    end

    def test_when_unknown_operator_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
                when: { lookback_days: { between: 30 } }
            output: { wallet: "{wallet}" }
      YAML
      assert_includes err, "unknown operator"
    end

    def test_when_non_numeric_operand_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
                when: { lookback_days: { gt: "many" } }
            output: { wallet: "{wallet}" }
      YAML
      assert_includes err, "requires a numeric operand"
    end

    def test_when_unbound_key_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
                when: { nope: { gt: 30 } }
            output: { wallet: "{wallet}" }
      YAML
      assert_includes err, "is not a bound name"
    end

    # The escape-hatch form is untouched — a plain ruby:/class: still loads.
    def test_ruby_form_still_valid
      err = load_error(<<~YAML)
        extract:
          ruby: ./extractor.rb
          class: My::Extractor
      YAML
      assert_nil err
    end

    # ── Ask 5: index_by / message verbs / skip_when / on_error ──────────

    def test_index_by_valid_loads
      assert_nil load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - index_by:
                  from: wallet
                  key: { path: identifiers, where: { type: LOCAL_UUID }, pick: value }
                  value: { path: identifiers, where: { type: UUID }, pick: value }
                as: uuid_map
            output: { m: "{uuid_map}" }
      YAML
    end

    def test_index_by_from_must_be_bound
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - index_by: { from: nope, key: k, value: v }
                as: m
            output: {}
      YAML
      assert_includes err, "not bound"
    end

    def test_index_by_requires_as
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - index_by: { from: wallet, key: k, value: v }
            output: {}
      YAML
      assert_includes err, "as:"
    end

    def test_index_by_bad_extractor_spec_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - index_by: { from: wallet, key: 3, value: v }
                as: m
            output: {}
      YAML
      assert_includes err, "dotted-path string or a hash"
    end

    def test_message_verbs_validate_and_check_refs
      assert_nil load_error(<<~YAML)
        extract:
          plan:
            steps:
              - note: "starting up"
              - warn: "since {from_date}"
              - abort: "hard stop"
                when: { lookback_days: { gt: 9999 } }
            output: {}
      YAML
    end

    def test_message_verb_unbound_ref_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - warn: "no uuid for {mystery}"
            output: {}
      YAML
      assert_includes err, "unbound name"
      assert_includes err, "mystery"
    end

    def test_skip_when_outside_for_each_is_rejected
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - skip_when: { lookback_days: { gt: 1 } }
            output: {}
      YAML
      assert_includes err, "unknown step"
    end

    def test_skip_when_inside_for_each_is_valid
      assert_nil load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: wallet
              - for_each: { source: wallet }
                as_item: row
                as: kept
                do:
                  - select: { from: row, path: kind }
                    as: kind
                  - skip_when: { kind: { eq: investment } }
                  - yield: "{row}"
            output: { kept: "{kept}" }
      YAML
    end

    def test_on_error_abort_valid
      assert_nil load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: position
                on_error: { abort: "position-keeping failed" }
            output: { p: "{position}" }
      YAML
    end

    def test_on_error_must_declare_exactly_one_of_abort_warn
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: w
                on_error: { abort: "a", warn: "b" }
            output: {}
      YAML
      assert_includes err, "exactly one"
    end

    def test_on_error_message_must_be_non_empty
      err = load_error(<<~YAML)
        extract:
          plan:
            steps:
              - fetch: fetch_wallet
                as: w
                on_error: { abort: "" }
            output: {}
      YAML
      assert_includes err, "non-empty"
    end
  end
end
