# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "date"

module Freentonic
  module ExtractPlan
    # Runtime semantics of the `apply:` verb inside a running plan: arg
    # resolution against the scope, binding, when: gating, per-iteration
    # calls inside for_each, and the deep-freeze contract end-to-end.
    # Fn-level semantics (params, types, purity) live in fn_test.rb.
    class ExtractPlanApplyTest < Minitest::Test
      def teardown
        Array(@defined_fns).each { |n| Fn.unregister(n) }
      end

      def define_fn(name, &definition)
        Fn.define(name, &definition)
        (@defined_fns ||= []) << name
      end

      # steps/output are explicit kwargs (not one positional Hash) so a
      # braceless call can't be swallowed as keyword arguments.
      def run_plan(steps:, output:, stderr: StringIO.new)
        PlanExtractor.new({ "steps" => steps, "output" => output }, endpoint_names: [])
                     .call(client: nil, credentials: {}, from_date: Date.new(2026, 1, 1),
                           stdout: StringIO.new, stderr: stderr)
      end

      def test_apply_resolves_args_from_scope_and_binds_result
        raw = run_plan(
          steps: [
            { "let" => "amount", "value" => 12.34 },
            { "apply" => "cents", "args" => { "amount" => "{amount}" }, "as" => "amount_cents" }
          ],
          output: { "cents" => "{amount_cents}" }
        )
        assert_equal({ "cents" => 1234 }, raw)
      end

      def test_apply_without_args_uses_param_defaults
        define_fn("fn_apply_test_const") do |f|
          f.description "constant"
          f.param :base, :integer, default: 41
          f.example args: {}, returns: 42
          f.impl { |base:| base + 1 }
        end
        raw = run_plan(
          steps: [{ "apply" => "fn_apply_test_const", "as" => "answer" }],
          output: { "answer" => "{answer}" }
        )
        assert_equal({ "answer" => 42 }, raw)
      end

      def test_apply_per_iteration_inside_for_each
        raw = run_plan(
          steps: [
            { "let" => "rows", "value" => [{ "amount" => "12,34" }, { "amount" => 5 }] },
            { "for_each" => { "source" => "rows" }, "as_item" => "row", "as" => "cents_list",
              "do" => [
                { "apply" => "cents", "args" => { "amount" => "{row.amount}" }, "as" => "c" },
                { "yield" => "{c}" }
              ] }
          ],
          output: { "cents_list" => "{cents_list}" }
        )
        assert_equal({ "cents_list" => [1234, 500] }, raw)
      end

      def test_apply_respects_when_gate
        raw = run_plan(
          steps: [
            { "let" => "amount", "value" => 12.34 },
            { "apply" => "cents", "args" => { "amount" => "{amount}" }, "as" => "skipped",
              "when" => { "amount" => { "absent" => true } } }
          ],
          output: { "skipped" => "{skipped}" }
        )
        assert_nil raw["skipped"]
      end

      def test_apply_unknown_function_at_runtime_raises_user_error
        err = assert_raises(UserError) do
          run_plan(steps: [{ "apply" => "vanished_fn", "as" => "x" }], output: {})
        end
        assert_includes err.message, "not a registered function"
      end

      def test_apply_freezes_scope_resolved_args_so_mutating_impl_raises
        define_fn("fn_apply_test_mutator") do |f|
          f.description "illegally mutates a bound collection"
          f.param :rows, :array, required: true
          f.example args: { "rows" => [] }, returns: []
          f.impl { |rows:| rows.each { |r| r["seen"] = true unless rows.empty? }; rows }
        end
        err = assert_raises(FrozenError) do
          run_plan(
            steps: [
              { "let" => "rows", "value" => [{ "a" => 1 }] },
              { "apply" => "fn_apply_test_mutator", "args" => { "rows" => "{rows}" }, "as" => "x" }
            ],
            output: {}
          )
        end
        assert_kind_of FrozenError, err
      end

      def test_apply_builds_canonical_entities_through_a_plan
        raw = run_plan(
          steps: [
            { "let" => "products",
              "value" => [{ "id" => "p1", "name" => "Main" }, { "id" => "p2", "name" => "Savings" }] },
            { "for_each" => { "source" => "products" }, "as_item" => "p", "as" => "accounts",
              "do" => [
                { "apply" => "build_account",
                  "args" => { "institution" => "testbank", "source_id" => "{p.id}",
                              "currency" => "EUR", "name" => "{p.name}" },
                  "as" => "account" },
                { "yield" => "{account}" }
              ] }
          ],
          output: { "accounts" => "{accounts}" }
        )
        accounts = raw["accounts"]
        assert_equal 2, accounts.length
        assert_equal %w[p1 p2], accounts.map(&:source_id)
        accounts.each { |a| assert_match(/\Aacc_\h{16}\z/, a.id) }
        refute_equal accounts[0].id, accounts[1].id
      end
    end
  end
end
