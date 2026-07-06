# frozen_string_literal: true

require_relative "test_helper"

module Freentonic
  class FnTest < Minitest::Test
    # Define a throwaway function for one test; teardown unregisters so
    # the closed-registry invariant holds for every other test.
    def define_fn(name, &definition)
      Fn.define(name, &definition)
      (@defined_fns ||= []) << name
    end

    def teardown
      Array(@defined_fns).each { |n| Fn.unregister(n) }
    end

    # ── definition contract ──────────────────────────────────────────────

    def test_define_rejects_missing_description
      err = assert_raises(ArgumentError) do
        Fn.define("fn_test_no_desc") do |f|
          f.example args: {}, returns: 1
          f.impl { 1 }
        end
      end
      assert_includes err.message, "must declare description"
    ensure
      Fn.unregister("fn_test_no_desc")
    end

    def test_define_rejects_missing_example
      err = assert_raises(ArgumentError) do
        Fn.define("fn_test_no_example") do |f|
          f.description "no example"
          f.impl { 1 }
        end
      end
      assert_includes err.message, "must declare examples"
    ensure
      Fn.unregister("fn_test_no_example")
    end

    def test_define_rejects_missing_impl
      err = assert_raises(ArgumentError) do
        Fn.define("fn_test_no_impl") do |f|
          f.description "no impl"
          f.example args: {}, returns: 1
        end
      end
      assert_includes err.message, "must declare impl"
    ensure
      Fn.unregister("fn_test_no_impl")
    end

    def test_define_rejects_duplicate_name
      Fn.define("fn_test_dup") do |f|
        f.description "first"
        f.example args: {}, returns: 1
        f.impl { 1 }
      end
      err = assert_raises(ArgumentError) do
        Fn.define("fn_test_dup") { |f| f.description "second" }
      end
      assert_includes err.message, "duplicate function name"
    ensure
      Fn.unregister("fn_test_dup")
    end

    def test_define_rejects_unknown_param_type
      err = assert_raises(ArgumentError) do
        Fn.define("fn_test_bad_type") do |f|
          f.description "bad type"
          f.param :value, :float
          f.example args: {}, returns: 1
          f.impl { |value:| value }
        end
      end
      assert_includes err.message, "unknown param type :float"
    ensure
      Fn.unregister("fn_test_bad_type")
    end

    def test_example_requires_exactly_one_of_returns_or_matching
      err = assert_raises(ArgumentError) do
        Fn.define("fn_test_example_mode") do |f|
          f.description "ambiguous example"
          f.example args: {}
          f.impl { 1 }
        end
      end
      assert_includes err.message, "exactly one of returns:/matching:"
    ensure
      Fn.unregister("fn_test_example_mode")
    end

    def test_example_returns_nil_is_a_legal_expectation
      define_fn("fn_test_nil_return") do |f|
        f.description "nil is a value"
        f.param :value
        f.example args: { "value" => nil }, returns: nil
        f.impl { |value:| value }
      end
    end

    # ── call semantics ───────────────────────────────────────────────────

    def test_call_unknown_function_raises_user_error_with_known_names
      err = assert_raises(UserError) { Fn.call("no_such_fn") }
      assert_includes err.message, '"no_such_fn" is not a registered function'
      assert_includes err.message, "cents"
    end

    def test_call_rejects_unknown_parameter
      err = assert_raises(UserError) { Fn.call("pan_last4", { "value" => "8619", "nope" => 1 }) }
      assert_includes err.message, "unknown parameter(s) nope"
      assert_includes err.message, "params: value"
    end

    def test_call_rejects_missing_required_parameter
      err = assert_raises(UserError) { Fn.call("pick", { "key" => "date" }) }
      assert_includes err.message, "missing required parameter(s)"
      assert_includes err.message, "aliases"
    end

    def test_call_rejects_type_mismatch
      err = assert_raises(UserError) do
        Fn.call("extract_fields", { "source" => {}, "mapping" => "not a hash" })
      end
      assert_includes err.message, "parameter mapping must be hash (got String)"
    end

    def test_call_applies_defaults_and_symbol_or_string_keys
      assert_equal 1234, Fn.call("cents", { "amount" => 12.34 })   # already_minor defaults false
      assert_equal 1234, Fn.call("cents", { amount: 1234, already_minor: true })
    end

    def test_call_deep_freezes_args_so_a_mutating_impl_raises
      define_fn("fn_test_mutator") do |f|
        f.description "illegally mutates its input"
        f.param :rows, :array, required: true
        f.example args: { "rows" => [] }, returns: []
        f.impl { |rows:| rows.empty? ? [] : rows.map! { nil } }
      end
      assert_raises(FrozenError) { Fn.call("fn_test_mutator", { "rows" => [{ "a" => 1 }] }) }
    end

    # ── L1 purity harness: every registered function, every example ─────
    #
    # Args are deep-frozen by Fn.call itself (mutation raises FrozenError),
    # each example runs twice (determinism), and the result must match the
    # declared returns:/matching:. A function with no example cannot exist
    # (define rejects it), so this covers the whole registry — including
    # every future Tier B addition, with zero new harness code.

    def test_every_registered_function_passes_its_examples_purely
      refute_empty Fn.all
      Fn.all.each do |defn|
        defn.examples.each_with_index do |ex, i|
          first  = Fn.call(defn.name, ex.args)
          second = Fn.call(defn.name, ex.args)
          if first.nil?
            assert_nil second, "#{defn.name} example #{i}: two calls disagreed (impure?)"
          else
            assert_equal first, second, "#{defn.name} example #{i}: two calls disagreed (impure?)"
          end

          if ex.matching
            # Entity to_h serializes with String keys.
            actual = first.to_h
            ex.matching.each do |attr, expected|
              assert_equal expected, actual[attr.to_s],
                           "#{defn.name} example #{i}: attribute #{attr} mismatch"
            end
          elsif ex.returns.nil?
            assert_nil first, "#{defn.name} example #{i}"
          else
            assert_equal ex.returns, first, "#{defn.name} example #{i}"
          end
        end
      end
    end

    # ── builtin spot checks beyond the examples ─────────────────────────

    def test_build_account_id_is_deterministic_and_portable_ref_driven
      base = { "institution" => "testbank", "source_id" => "s1", "currency" => "EUR",
               "name" => "Main" }
      by_source   = Fn.call("build_account", base)
      by_portable = Fn.call("build_account", base.merge("portable_ref" => "1465:7890",
                                                        "portable_id" => "bank:1465:7890"))
      assert_match(/\Aacc_\h{16}\z/, by_source.id)
      refute_equal by_source.id, by_portable.id
      assert_equal by_portable.id,
                   Fn.call("build_account", { "institution" => "otherbank", "source_id" => "s2",
                                              "currency" => "EUR", "portable_ref" => "1465:7890" }).id
    end

    def test_build_transaction_and_liability_chain_on_account_id
      account = Fn.call("build_account", { "institution" => "testbank", "source_id" => "s1",
                                           "currency" => "EUR" })
      txn = Fn.call("build_transaction", { "account_id" => account.id, "amount" => BigDecimal("-5"),
                                           "currency" => "EUR", "source_id" => "t1" })
      liab = Fn.call("build_liability", { "account_id" => account.id, "type" => "credit_card",
                                          "currency" => "EUR" })
      assert_equal account.id, txn.account_id
      assert_match(/\Atxn_\h{16}\z/, txn.id)
      assert_match(/\Aliab_\h{16}\z/, liab.id)
    end

    # ── collapse_prefix_dups: the ING pre-clearing edge cases, incl. the
    #    entity-reading path PathDig exists for ─────────────────────────────

    # Helper: a canonical transaction with a given account/date/amount/desc.
    def txn(acc, date, amount, desc)
      Fn.call("build_transaction",
              { "account_id" => acc, "amount" => amount, "currency" => "EUR",
                "source_id" => desc, "date" => date, "description" => desc })
    end

    def collapse(rows)
      Fn.call("collapse_prefix_dups",
              { "rows" => rows, "group_by" => %w[account_id date amount], "text" => "description" })
    end

    def test_collapse_reads_entity_members_and_drops_terse_prefix
      d = Date.new(2026, 5, 21)
      terse    = txn("acc_1", d, BigDecimal("-26.38"), "WWW.AMAZON")
      enriched = txn("acc_1", d, BigDecimal("-26.38"), "WWW.AMAZON*NO3CS7J44 LUXEMBOURG")
      survivors = collapse([terse, enriched])
      assert_equal [enriched.id], survivors.map(&:id),
                   "terse row is a strict prefix → collapse to the enriched row"
    end

    def test_collapse_keeps_identical_twins_and_mid_string_divergence
      d = Date.new(2026, 5, 20)
      twin_a = txn("acc_1", d, BigDecimal("-80"), "AYUNTAMIENTO ALCOBENDAS")
      twin_b = txn("acc_1", d, BigDecimal("-80"), "AYUNTAMIENTO ALCOBENDAS")
      assert_equal 2, collapse([twin_a, twin_b]).size, "identical twins both survive"

      cafe  = txn("acc_1", d, BigDecimal("-60"), "CAFE DE SAN MILLAN")
      petro = txn("acc_1", d, BigDecimal("-60"), "PETROPRIX ALCOBENDAS")
      assert_equal 2, collapse([cafe, petro]).size, "mid-string divergence keeps both"
    end

    def test_collapse_three_way_mixed_group_keeps_all_and_scopes_by_account
      d = Date.new(2026, 5, 21)
      terse     = txn("acc_1", d, BigDecimal("-26.38"), "WWW.AMAZON")
      enriched  = txn("acc_1", d, BigDecimal("-26.38"), "WWW.AMAZON*NO3 LUXEMBOURG")
      unrelated = txn("acc_1", d, BigDecimal("-26.38"), "WWW.AMAZON GIFT CARD")
      assert_equal 3, collapse([terse, enriched, unrelated]).size,
                   "a third non-prefix row leaves the whole group for review"

      # Same date+amount+desc on two accounts must not collapse — group key
      # includes account_id.
      a = txn("acc_1", d, BigDecimal("-10"), "STARBUCKS MADRID")
      b = txn("acc_2", d, BigDecimal("-10"), "STARBUCKS MADRID")
      assert_equal 2, collapse([a, b]).size, "collapse is scoped per account"
    end
  end
end
