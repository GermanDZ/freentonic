# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "date"

module Freentonic
  module ExtractPlan
    class ExtractPlanTest < Minitest::Test
      # A fake api_client: endpoint methods are just public methods that
      # return canned data. `calls` records each invocation so tests can
      # assert on the orchestration (args threaded between steps, per-item
      # loop calls). `raise_on` lets a named endpoint blow up to exercise
      # `safe:` and SessionExpired propagation.
      class FakeClient
        attr_reader :calls

        def initialize(responses: {}, raise_on: {})
          @responses = responses
          @raise_on  = raise_on
          @calls     = []
        end

        def fetch_wallet
          record(:fetch_wallet, {})
          @responses.fetch(:fetch_wallet)
        end

        def fetch_cards
          record(:fetch_cards, {})
          @responses.fetch(:fetch_cards, [])
        end

        def fetch_vaults
          record(:fetch_vaults, {})
          @responses.fetch(:fetch_vaults, [])
        end

        def fetch_bank_details(currency:)
          record(:fetch_bank_details, currency: currency)
          (@responses[:fetch_bank_details] || {})[currency]
        end

        def fetch_pocket_transactions(pocket_id:, from_ms:, now_ms: nil)
          record(:fetch_pocket_transactions, pocket_id: pocket_id, from_ms: from_ms, now_ms: now_ms)
          (@responses[:fetch_pocket_transactions] || {})[pocket_id] || []
        end

        private

        def record(name, args)
          @calls << [name, args]
          if (err = @raise_on[name])
            raise err
          end
        end
      end

      ENDPOINTS = %w[fetch_wallet fetch_cards fetch_vaults
                     fetch_bank_details fetch_pocket_transactions].freeze

      def run_plan(plan, client:, from_date: Date.new(2026, 1, 1), stderr: StringIO.new)
        extractor = PlanExtractor.new(plan, endpoint_names: ENDPOINTS)
        extractor.call(client: client, credentials: {}, from_date: from_date,
                       stdout: StringIO.new, stderr: stderr)
      end

      # ── single fetch → output ───────────────────────────────────────────

      def test_single_fetch_binds_and_assembles
        client = FakeClient.new(responses: { fetch_wallet: { "id" => 7 } })
        plan = {
          "steps"  => [{ "fetch" => "fetch_wallet", "as" => "wallet" }],
          "output" => { "wallet" => "{wallet}" }
        }
        assert_equal({ "wallet" => { "id" => 7 } }, run_plan(plan, client: client))
      end

      # ── select digs a sub-value (single path, dotted, fallback chain) ────

      def test_select_single_and_dotted_and_fallback
        client = FakeClient.new(responses: {
          fetch_wallet: { "pockets" => [1, 2], "meta" => { "region" => "eu" } }
        })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "select" => { "from" => "wallet", "path" => "pockets" }, "as" => "pockets" },
            { "select" => { "from" => "wallet", "path" => "meta.region" }, "as" => "region" },
            { "select" => { "from" => "wallet", "path" => %w[missing meta.region] }, "as" => "chained" }
          ],
          "output" => { "p" => "{pockets}", "r" => "{region}", "c" => "{chained}" }
        }
        assert_equal({ "p" => [1, 2], "r" => "eu", "c" => "eu" }, run_plan(plan, client: client))
      end

      def test_select_default_when_missing
        client = FakeClient.new(responses: { fetch_wallet: {} })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "select" => { "from" => "wallet", "path" => "pockets", "default" => [] }, "as" => "pockets" }
          ],
          "output" => { "pockets" => "{pockets}" }
        }
        assert_equal({ "pockets" => [] }, run_plan(plan, client: client))
      end

      # ── for_each collect: array, with pluck/uniq/compact + skip_if_nil ───

      def test_for_each_array_with_pluck_uniq_compact
        client = FakeClient.new(responses: {
          fetch_wallet: { "pockets" => [
            { "currency" => "USD" }, { "currency" => "EUR" },
            { "currency" => "USD" }, { "currency" => nil }
          ] },
          fetch_bank_details: { "USD" => { "iban" => "US1" }, "EUR" => { "iban" => "EU1" } }
        })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "select" => { "from" => "wallet", "path" => "pockets" }, "as" => "pockets" },
            {
              "for_each" => { "source" => "pockets", "pluck" => "currency", "uniq" => true, "compact" => true },
              "as_item"  => "currency",
              "as"       => "bank_details",
              "do" => [
                { "fetch" => "fetch_bank_details", "args" => { "currency" => "{currency}" }, "as" => "detail", "safe" => true },
                { "yield" => { "currency" => "{currency}", "details" => "{detail}" }, "skip_if_nil" => "detail" }
              ]
            }
          ],
          "output" => { "bank_details" => "{bank_details}" }
        }
        result = run_plan(plan, client: client)
        assert_equal([
          { "currency" => "USD", "details" => { "iban" => "US1" } },
          { "currency" => "EUR", "details" => { "iban" => "EU1" } }
        ], result["bank_details"])
        # pluck→compact→uniq: two distinct non-nil currencies → two calls.
        detail_calls = client.calls.select { |(n, _)| n == :fetch_bank_details }
        assert_equal [%i[USD], %i[EUR]].map { |c| [:fetch_bank_details, { currency: c.first.to_s }] },
                     detail_calls
      end

      def test_skip_if_nil_drops_iteration
        client = FakeClient.new(responses: {
          fetch_wallet: { "pockets" => [{ "currency" => "USD" }, { "currency" => "GBP" }] },
          fetch_bank_details: { "USD" => { "iban" => "US1" } } # GBP → nil
        })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "select" => { "from" => "wallet", "path" => "pockets" }, "as" => "pockets" },
            {
              "for_each" => { "source" => "pockets", "pluck" => "currency" },
              "as_item"  => "currency", "as" => "bank_details",
              "do" => [
                { "fetch" => "fetch_bank_details", "args" => { "currency" => "{currency}" }, "as" => "detail", "safe" => true },
                { "yield" => { "currency" => "{currency}", "details" => "{detail}" }, "skip_if_nil" => "detail" }
              ]
            }
          ],
          "output" => { "bank_details" => "{bank_details}" }
        }
        result = run_plan(plan, client: client)
        assert_equal [{ "currency" => "USD", "details" => { "iban" => "US1" } }], result["bank_details"]
      end

      # ── for_each collect: map, keyed by a dotted token ──────────────────

      def test_for_each_map_keyed_by_field_threads_from_ms
        client = FakeClient.new(responses: {
          fetch_wallet: { "pockets" => [{ "id" => "p1" }, { "id" => "p2" }] },
          fetch_pocket_transactions: { "p1" => [{ "t" => 1 }], "p2" => [] }
        })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "select" => { "from" => "wallet", "path" => "pockets" }, "as" => "pockets" },
            {
              "for_each" => { "source" => "pockets" },
              "as_item"  => "pocket", "as" => "pocket_transactions",
              "collect"  => "map", "key" => "{pocket.id}",
              "do" => [
                { "fetch" => "fetch_pocket_transactions",
                  "args" => { "pocket_id" => "{pocket.id}", "from_ms" => "{from_ms}", "now_ms" => "{now_ms}" },
                  "as" => "txns", "safe" => true, "default" => [] },
                { "yield" => "{txns}" }
              ]
            }
          ],
          "output" => { "pocket_transactions" => "{pocket_transactions}" }
        }
        result = run_plan(plan, client: client, from_date: Date.new(2026, 1, 1))
        assert_equal({ "p1" => [{ "t" => 1 }], "p2" => [] }, result["pocket_transactions"])

        # from_ms threaded correctly: 2026-01-01 → epoch ms.
        expected_ms = Date.new(2026, 1, 1).to_time.to_i * 1000
        tx_call = client.calls.find { |(n, _)| n == :fetch_pocket_transactions }
        assert_equal expected_ms, tx_call[1][:from_ms]
        assert_equal "p1", tx_call[1][:pocket_id]
      end

      # ── safe: rescues ApiError, honors default ──────────────────────────

      def test_safe_fetch_degrades_to_default_and_logs
        client = FakeClient.new(
          responses: { fetch_wallet: { "ok" => true } },
          raise_on: { fetch_cards: ApiClient::ApiError.new(500, "boom") }
        )
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "fetch" => "fetch_cards", "as" => "cards", "safe" => true, "default" => [] }
          ],
          "output" => { "wallet" => "{wallet}", "cards" => "{cards}" }
        }
        stderr = StringIO.new
        result = run_plan(plan, client: client, stderr: stderr)
        assert_equal({ "wallet" => { "ok" => true }, "cards" => [] }, result)
        assert_includes stderr.string, "fetch_cards"
      end

      # ── SessionExpired ALWAYS propagates, even under safe: ──────────────

      def test_session_expired_propagates_through_safe
        client = FakeClient.new(
          responses: { fetch_wallet: {} },
          raise_on: { fetch_cards: ApiClient::SessionExpired.new("session expired (HTTP 401)") }
        )
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "fetch" => "fetch_cards", "as" => "cards", "safe" => true, "default" => [] }
          ],
          "output" => { "cards" => "{cards}" }
        }
        assert_raises(ApiClient::SessionExpired) { run_plan(plan, client: client) }
      end

      # ── an unsafe fetch failure raises (no swallowing) ──────────────────

      def test_unsafe_fetch_failure_raises
        client = FakeClient.new(
          responses: { fetch_wallet: {} },
          raise_on: { fetch_cards: ApiClient::ApiError.new(500, "boom") }
        )
        plan = {
          "steps" => [{ "fetch" => "fetch_cards", "as" => "cards" }],
          "output" => { "cards" => "{cards}" }
        }
        assert_raises(ApiClient::ApiError) { run_plan(plan, client: client) }
      end

      # ── extract_batch unwraps a hash-wrapped array ──────────────────────

      def test_extract_batch_unwraps
        client = FakeClient.new(responses: { fetch_cards: { "items" => [1, 2, 3] } })
        plan = {
          "steps" => [{ "fetch" => "fetch_cards", "as" => "cards", "extract_batch" => %w[items] }],
          "output" => { "cards" => "{cards}" }
        }
        assert_equal({ "cards" => [1, 2, 3] }, run_plan(plan, client: client))
      end

      # ── literals in output/args pass through untouched ──────────────────

      # ── parity: a plan produces exactly what the hand-written Ruby ──────
      #    orchestration does, for the full Revolut shape. This is the
      #    behavioral-equivalence lock behind "revolut → zero Ruby".

      # The orchestration `revolut/extractor.rb` performs, distilled: fetch
      # wallet → pluck+dedup currencies → per-currency bank details (array)
      # → cards/vaults (tolerant) → per-pocket transactions (map by id).
      def ruby_equivalent(client, from_date, stderr)
        from_ms = from_date.to_time.to_i * 1000
        wallet  = client.fetch_wallet
        pockets = wallet.is_a?(Hash) ? (wallet["pockets"] || []) : []

        bank_details = []
        pockets.map { |p| p["currency"] }.compact.uniq.each do |currency|
          detail = safe(stderr) { client.fetch_bank_details(currency: currency) }
          bank_details << { "currency" => currency, "details" => detail } if detail
        end

        cards  = safe(stderr) { client.fetch_cards }
        vaults = safe(stderr) { client.fetch_vaults }

        pocket_transactions = {}
        pockets.each do |pocket|
          pid = pocket["id"]
          pocket_transactions[pid] =
            safe(stderr) { client.fetch_pocket_transactions(pocket_id: pid, from_ms: from_ms) } || []
        end

        {
          "wallet" => wallet, "pockets" => pockets, "bank_details" => bank_details,
          "cards" => cards, "vaults" => vaults, "pocket_transactions" => pocket_transactions
        }
      end

      def safe(stderr)
        yield
      rescue ApiClient::SessionExpired
        raise
      rescue StandardError => e
        stderr.puts "  ✗ #{e.message}"
        nil
      end

      REVOLUT_PLAN = {
        "steps" => [
          { "fetch" => "fetch_wallet", "as" => "wallet" },
          { "select" => { "from" => "wallet", "path" => "pockets", "default" => [] }, "as" => "pockets" },
          {
            "for_each" => { "source" => "pockets", "pluck" => "currency", "compact" => true, "uniq" => true },
            "as_item" => "currency", "as" => "bank_details",
            "do" => [
              { "fetch" => "fetch_bank_details", "args" => { "currency" => "{currency}" }, "as" => "detail", "safe" => true },
              { "yield" => { "currency" => "{currency}", "details" => "{detail}" }, "skip_if_nil" => "detail" }
            ]
          },
          { "fetch" => "fetch_cards", "as" => "cards", "safe" => true },
          { "fetch" => "fetch_vaults", "as" => "vaults", "safe" => true },
          {
            "for_each" => { "source" => "pockets" },
            "as_item" => "pocket", "as" => "pocket_transactions", "collect" => "map", "key" => "{pocket.id}",
            "do" => [
              { "fetch" => "fetch_pocket_transactions",
                "args" => { "pocket_id" => "{pocket.id}", "from_ms" => "{from_ms}" },
                "as" => "txns", "safe" => true, "default" => [] },
              { "yield" => "{txns}" }
            ]
          }
        ],
        "output" => {
          "wallet" => "{wallet}", "pockets" => "{pockets}", "bank_details" => "{bank_details}",
          "cards" => "{cards}", "vaults" => "{vaults}", "pocket_transactions" => "{pocket_transactions}"
        }
      }.freeze

      def revolut_responses
        {
          fetch_wallet: { "pockets" => [
            { "id" => "p_usd", "currency" => "USD" },
            { "id" => "p_eur", "currency" => "EUR" },
            { "id" => "p_usd2", "currency" => "USD" }
          ] },
          fetch_bank_details: { "USD" => { "iban" => "US99" }, "EUR" => { "iban" => "EU99" } },
          fetch_cards: [{ "id" => "card1" }],
          fetch_vaults: [{ "id" => "vault1" }],
          fetch_pocket_transactions: {
            "p_usd"  => [{ "t" => 1 }], "p_eur" => [{ "t" => 2 }], "p_usd2" => []
          }
        }
      end

      def test_plan_matches_hand_written_ruby_orchestration
        from_date = Date.new(2026, 3, 1)
        ruby_out = ruby_equivalent(FakeClient.new(responses: revolut_responses), from_date, StringIO.new)
        plan_out = run_plan(REVOLUT_PLAN, client: FakeClient.new(responses: revolut_responses), from_date: from_date)
        assert_equal ruby_out, plan_out
      end

      def test_literals_pass_through
        client = FakeClient.new(responses: { fetch_wallet: { "x" => 1 } })
        plan = {
          "steps"  => [{ "fetch" => "fetch_wallet", "as" => "wallet" }],
          "output" => { "wallet" => "{wallet}", "source" => "revolut", "count" => 42, "flag" => true }
        }
        assert_equal({ "wallet" => { "x" => 1 }, "source" => "revolut", "count" => 42, "flag" => true },
                     run_plan(plan, client: client))
      end

      # ── Phase-2: let / coalesce ─────────────────────────────────────────

      def test_let_coalesce_picks_first_non_nil
        client = FakeClient.new(responses: { fetch_wallet: { "meta" => { "a" => nil, "b" => "hit" } } })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "let" => "picked",
              "coalesce" => ["{wallet.meta.a}", "{wallet.meta.b}", "fallback"] }
          ],
          "output" => { "picked" => "{picked}" }
        }
        assert_equal({ "picked" => "hit" }, run_plan(plan, client: client))
      end

      def test_let_coalesce_falls_through_to_literal
        client = FakeClient.new(responses: { fetch_wallet: {} })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "let" => "picked", "coalesce" => ["{wallet.nope}", "2015-01-01"] }
          ],
          "output" => { "picked" => "{picked}" }
        }
        assert_equal({ "picked" => "2015-01-01" }, run_plan(plan, client: client))
      end

      def test_let_value_and_days_ago
        client = FakeClient.new(responses: { fetch_wallet: {} })
        from_date = Date.new(2026, 6, 1)
        plan = {
          "steps" => [
            { "let" => "start", "value" => "{from_date}" },
            { "let" => "cutoff", "days_ago" => 30 }
          ],
          "output" => { "start" => "{start}", "cutoff" => "{cutoff}" }
        }
        result = run_plan(plan, client: client, from_date: from_date)
        assert_equal from_date, result["start"]
        assert_equal Date.today - 30, result["cutoff"]
      end

      # ── Phase-2: concat (incl. Array-coercing an unbound/when-skipped) ───

      def test_concat_merges_bound_arrays
        client = FakeClient.new(responses: {})
        plan = {
          "steps" => [
            { "let" => "a", "value" => [1, 2] },
            { "let" => "b", "value" => [3] },
            { "concat" => %w[a b], "as" => "all" }
          ],
          "output" => { "all" => "{all}" }
        }
        assert_equal({ "all" => [1, 2, 3] }, run_plan(plan, client: client))
      end

      # ── Phase-2: dedup_by (first-wins, fallback keys, nil passthrough) ──

      def test_dedup_by_single_key_keeps_first
        client = FakeClient.new(responses: {})
        rows = [{ "id" => "a", "n" => 1 }, { "id" => "b" }, { "id" => "a", "n" => 2 }]
        plan = {
          "steps" => [
            { "let" => "rows", "value" => rows },
            { "dedup_by" => "id", "from" => "rows", "as" => "out" }
          ],
          "output" => { "out" => "{out}" }
        }
        assert_equal([{ "id" => "a", "n" => 1 }, { "id" => "b" }],
                     run_plan(plan, client: client)["out"])
      end

      def test_dedup_by_fallback_keys_and_nil_passthrough
        client = FakeClient.new(responses: {})
        # numMovimiento wins when present; nummov is the fallback; a row
        # with neither passes through unconditionally (kept twice).
        rows = [
          { "numMovimiento" => "375", "src" => "ext" },
          { "nummov" => "375", "src" => "std" },          # same logical key → dropped
          { "src" => "keyless-1" },                        # nil key → kept
          { "src" => "keyless-2" }                         # nil key → kept
        ]
        plan = {
          "steps" => [
            { "let" => "rows", "value" => rows },
            { "dedup_by" => %w[numMovimiento nummov], "from" => "rows", "as" => "out" }
          ],
          "output" => { "out" => "{out}" }
        }
        out = run_plan(plan, client: client)["out"]
        assert_equal ["ext", "keyless-1", "keyless-2"], out.map { |r| r["src"] }
      end

      # ── Phase-2: when: gate (present + numeric), incl. skipped-fetch ────

      def test_when_gate_skips_fetch_and_downstream_reads_empty
        # lookback_days for from_date = today-10 is 10, so gt:30 is false:
        # the extended fetch is skipped, `old` stays unbound, and concat
        # Array-coerces it to [] → merged == recent.
        client = FakeClient.new(
          responses: { fetch_wallet: { "recent" => true } },
          raise_on:  { fetch_cards: ApiClient::ApiError.new(500, "should not be called") }
        )
        plan = {
          "steps" => [
            { "let" => "recent", "value" => [{ "r" => 1 }] },
            { "fetch" => "fetch_cards", "as" => "old",
              "when" => { "lookback_days" => { "gt" => 30 } } },
            { "concat" => %w[old recent], "as" => "merged" }
          ],
          "output" => { "merged" => "{merged}" }
        }
        result = run_plan(plan, client: client, from_date: Date.today - 10)
        assert_equal({ "merged" => [{ "r" => 1 }] }, result)
        assert_empty client.calls   # fetch_cards never invoked
      end

      def test_when_gate_runs_fetch_when_condition_holds
        client = FakeClient.new(responses: { fetch_cards: [{ "c" => 1 }] })
        plan = {
          "steps" => [
            { "fetch" => "fetch_cards", "as" => "cards",
              "when" => { "lookback_days" => { "gt" => 30 } } }
          ],
          "output" => { "cards" => "{cards}" }
        }
        result = run_plan(plan, client: client, from_date: Date.today - 90)
        assert_equal({ "cards" => [{ "c" => 1 }] }, result)
        refute_empty client.calls
      end

      def test_when_present_gate_inside_for_each
        # ppp present → fetch; absent → skip via when, yield still runs.
        client = FakeClient.new(responses: {
          fetch_wallet: { "rows" => [{ "ppp" => "A" }, { "other" => "x" }] },
          fetch_bank_details: { "A" => { "iban" => "A1" } }
        })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "select" => { "from" => "wallet", "path" => "rows" }, "as" => "rows" },
            {
              "for_each" => { "source" => "rows" },
              "as_item" => "row", "as" => "details",
              "do" => [
                { "select" => { "from" => "row", "path" => "ppp" }, "as" => "ppp" },
                { "fetch" => "fetch_bank_details", "args" => { "currency" => "{ppp}" },
                  "as" => "detail", "when" => { "ppp" => { "present" => true } } },
                { "yield" => "{detail}" }
              ]
            }
          ],
          "output" => { "details" => "{details}" }
        }
        result = run_plan(plan, client: client)
        # Row A fetches its detail; the keyless row skips the fetch → nil.
        assert_equal [{ "iban" => "A1" }, nil], result["details"]
        assert_equal 1, client.calls.count { |(n, _)| n == :fetch_bank_details }
      end

      # ── Ask 5: index_by, message verbs, skip_when, fetch on_error ───────

      # Run capturing stdout/stderr (message verbs write to them).
      def run_plan_io(plan, client:, from_date: Date.new(2026, 1, 1))
        out = StringIO.new
        err = StringIO.new
        result = PlanExtractor.new(plan, endpoint_names: ENDPOINTS)
                              .call(client: client, credentials: {}, from_date: from_date,
                                    stdout: out, stderr: err)
        [result, out.string, err.string]
      end

      def test_index_by_builds_map_via_find_by_field
        # The ING build_uuid_map shape: LOCAL_UUID value → UUID value.
        products = [
          { "identifiers" => [{ "type" => "LOCAL_UUID", "value" => "v1a" },
                              { "type" => "UUID", "value" => "uuidA" }] },
          { "identifiers" => [{ "type" => "LOCAL_UUID", "value" => "v1b" },
                              { "type" => "UUID", "value" => "uuidB" }] }
        ]
        plan = {
          "steps" => [
            { "let" => "products", "value" => products },
            { "index_by" => {
              "from"  => "products",
              "key"   => { "path" => "identifiers", "where" => { "type" => "LOCAL_UUID" }, "pick" => "value" },
              "value" => { "path" => "identifiers", "where" => { "type" => "UUID" }, "pick" => "value" }
            }, "as" => "uuid_map" }
          ],
          "output" => { "uuid_map" => "{uuid_map}" }
        }
        assert_equal({ "uuid_map" => { "v1a" => "uuidA", "v1b" => "uuidB" } },
                     run_plan(plan, client: FakeClient.new(responses: {})))
      end

      def test_index_by_drops_nil_key_and_blank_value
        products = [
          { "identifiers" => [{ "type" => "LOCAL_UUID", "value" => "v1" },
                              { "type" => "UUID", "value" => "u1" }] },
          { "identifiers" => [{ "type" => "UUID", "value" => "u2" }] },                 # no LOCAL_UUID → nil key, dropped
          { "identifiers" => [{ "type" => "LOCAL_UUID", "value" => "v3" },
                              { "type" => "UUID", "value" => "" }] }                     # blank value, dropped
        ]
        plan = {
          "steps" => [
            { "let" => "products", "value" => products },
            { "index_by" => {
              "from"  => "products",
              "key"   => { "path" => "identifiers", "where" => { "type" => "LOCAL_UUID" }, "pick" => "value" },
              "value" => { "path" => "identifiers", "where" => { "type" => "UUID" }, "pick" => "value" }
            }, "as" => "m" }
          ],
          "output" => { "m" => "{m}" }
        }
        assert_equal({ "m" => { "v1" => "u1" } }, run_plan(plan, client: FakeClient.new(responses: {})))
      end

      def test_index_by_with_string_path_key_and_value
        rows = [{ "k" => "a", "v" => 1 }, { "k" => "b", "v" => 2 }]
        plan = {
          "steps" => [
            { "let" => "rows", "value" => rows },
            { "index_by" => { "from" => "rows", "key" => "k", "value" => "v" }, "as" => "m" }
          ],
          "output" => { "m" => "{m}" }
        }
        assert_equal({ "m" => { "a" => 1, "b" => 2 } }, run_plan(plan, client: FakeClient.new(responses: {})))
      end

      def test_note_and_warn_write_to_streams_with_interpolation
        plan = {
          "steps" => [
            { "let" => "who", "value" => "Alice" },
            { "note" => "serving {who}" },
            { "warn" => "no uuid for {who}" }
          ],
          "output" => {}
        }
        _result, out, err = run_plan_io(plan, client: FakeClient.new(responses: {}))
        assert_includes out, "serving Alice"
        assert_includes err, "no uuid for Alice"
      end

      def test_abort_raises_user_error
        plan = {
          "steps" => [{ "abort" => "preflight failed: no bearer" }],
          "output" => {}
        }
        err = assert_raises(UserError) { run_plan(plan, client: FakeClient.new(responses: {})) }
        assert_includes err.message, "preflight failed: no bearer"
      end

      def test_message_respects_when_gate
        # lookback_days = 5, gate gt:30 false → abort is skipped.
        plan = {
          "steps" => [{ "abort" => "should not fire", "when" => { "lookback_days" => { "gt" => 30 } } }],
          "output" => {}
        }
        run_plan(plan, client: FakeClient.new(responses: {}), from_date: Date.today - 5) # no raise
      end

      def test_skip_when_drops_iteration_and_warns
        client = FakeClient.new(responses: {
          fetch_wallet: { "rows" => [{ "id" => "keep", "kind" => "asset" },
                                     { "id" => "drop", "kind" => "investment" }] }
        })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet" },
            { "select" => { "from" => "wallet", "path" => "rows" }, "as" => "rows" },
            {
              "for_each" => { "source" => "rows" },
              "as_item" => "row", "as" => "kept",
              "do" => [
                { "select" => { "from" => "row", "path" => "kind" }, "as" => "kind" },
                { "warn" => "skipping {row.id}", "when" => { "kind" => { "eq" => "investment" } } },
                { "skip_when" => { "kind" => { "eq" => "investment" } } },
                { "yield" => "{row.id}" }
              ]
            }
          ],
          "output" => { "kept" => "{kept}" }
        }
        result, _out, err = run_plan_io(plan, client: client)
        assert_equal ["keep"], result["kept"]
        assert_includes err, "skipping drop"
      end

      def test_fetch_on_error_abort_raises_custom_message_even_for_session_expired
        client = FakeClient.new(responses: {},
                                raise_on: { fetch_wallet: ApiClient::SessionExpired.new("401") })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "position",
              "on_error" => { "abort" => "position-keeping failed — re-run after fresh login" } }
          ],
          "output" => { "position" => "{position}" }
        }
        err = assert_raises(UserError) { run_plan(plan, client: client) }
        assert_includes err.message, "re-run after fresh login"
      end

      def test_fetch_on_error_warn_degrades_to_default
        client = FakeClient.new(responses: {},
                                raise_on: { fetch_wallet: ApiClient::ApiError.new(500, "boom") })
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "w",
              "on_error" => { "warn" => "optional fetch failed" }, "default" => { "fallback" => true } }
          ],
          "output" => { "w" => "{w}" }
        }
        result, _out, err = run_plan_io(plan, client: client)
        assert_equal({ "w" => { "fallback" => true } }, result)
        assert_includes err, "optional fetch failed"
      end

      # ── Ask 6: lookup (dynamic-key map read) ─────────────────────────────

      def test_lookup_reads_map_with_runtime_key
        plan = {
          "steps" => [
            { "let" => "uuid_map", "value" => { "v1a" => "uuidA", "v1b" => "uuidB" } },
            { "let" => "key", "value" => "v1b" },
            { "lookup" => { "from" => "uuid_map", "key" => "{key}" }, "as" => "hit" }
          ],
          "output" => { "hit" => "{hit}" }
        }
        assert_equal({ "hit" => "uuidB" }, run_plan(plan, client: FakeClient.new(responses: {})))
      end

      def test_lookup_missing_key_binds_nil_then_default
        plan = {
          "steps" => [
            { "let" => "uuid_map", "value" => { "known" => "u1" } },
            { "lookup" => { "from" => "uuid_map", "key" => "absent" }, "as" => "miss" },
            { "lookup" => { "from" => "uuid_map", "key" => "absent", "default" => "fallback" }, "as" => "defaulted" }
          ],
          "output" => { "miss" => "{miss}", "defaulted" => "{defaulted}" }
        }
        assert_equal({ "miss" => nil, "defaulted" => "fallback" },
                     run_plan(plan, client: FakeClient.new(responses: {})))
      end

      def test_lookup_unbound_or_non_hash_from_binds_nil
        # `from:` names a when-skipped (unbound) fetch's as: — a nil map.
        plan = {
          "steps" => [
            { "fetch" => "fetch_wallet", "as" => "wallet",
              "when" => { "lookback_days" => { "gt" => 9999 } } }, # skipped → unbound
            { "lookup" => { "from" => "wallet", "key" => "anything" }, "as" => "v" }
          ],
          "output" => { "v" => "{v}" }
        }
        assert_equal({ "v" => nil }, run_plan(plan, client: FakeClient.new(responses: {})))
      end

      # The ING join Ask 6 unlocks: per-product lookup of a v2 UUID, warn +
      # skip on absent, yield the joined row.
      def test_lookup_joins_two_lists_per_iteration_with_skip
        plan = {
          "steps" => [
            { "let" => "uuid_map", "value" => { "L1" => "u1", "L3" => "u3" } },
            { "let" => "products", "value" => [
              { "uuid" => "L1", "alias" => "checking" },
              { "uuid" => "L2", "alias" => "orphan" },   # no v2 UUID → warn + skip
              { "uuid" => "L3", "alias" => "savings" }
            ] },
            {
              "for_each" => { "source" => "products" },
              "as_item" => "product", "as" => "joined",
              "do" => [
                { "lookup" => { "from" => "uuid_map", "key" => "{product.uuid}" }, "as" => "v2_uuid" },
                { "warn" => "no v2 UUID for {product.alias}", "when" => { "v2_uuid" => { "absent" => true } } },
                { "skip_when" => { "v2_uuid" => { "absent" => true } } },
                { "yield" => { "uuid" => "{v2_uuid}", "alias" => "{product.alias}" } }
              ]
            }
          ],
          "output" => { "joined" => "{joined}" }
        }
        result, _out, err = run_plan_io(plan, client: FakeClient.new(responses: {}))
        assert_equal([{ "uuid" => "u1", "alias" => "checking" },
                      { "uuid" => "u3", "alias" => "savings" }], result["joined"])
        assert_includes err, "no v2 UUID for orphan"
      end
    end
  end
end
