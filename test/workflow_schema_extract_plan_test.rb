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

    # The escape-hatch form is untouched — a plain ruby:/class: still loads.
    def test_ruby_form_still_valid
      err = load_error(<<~YAML)
        extract:
          ruby: ./extractor.rb
          class: My::Extractor
      YAML
      assert_nil err
    end
  end
end
