# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"
require "csv"
require "json"

module Freentonic
  # End-to-end exercise of the in-repo example workflow:
  #   examples/example_bank.yml + examples/extractor.rb + examples/normalizer.rb
  # piped through Normalize + Export against a checked-in raw fixture.
  #
  # Verifies that the example normalizer actually produces a CanonicalPayload
  # and that the standard exporters render it correctly. Acts as both a
  # regression guard for the example and a smoke test for the canonical
  # pipeline as a whole.
  class ExampleWorkflowIntegrationTest < Minitest::Test
    EXAMPLE_DIR = File.expand_path("../examples", __dir__)
    WORKFLOW    = File.join(EXAMPLE_DIR, "example_bank.yml")
    RAW_FIXTURE = File.join(EXAMPLE_DIR, "raw.example.json")

    # The example workflow uses provider Ruby (extract/normalize), so this
    # end-to-end run must opt into it past the Ask 10 capability gate.
    def setup
      @prev_ruby_gate = ENV[RubyCapability::ENV_VAR]
      ENV[RubyCapability::ENV_VAR] = "1"
    end

    def teardown
      @prev_ruby_gate.nil? ? ENV.delete(RubyCapability::ENV_VAR) : ENV[RubyCapability::ENV_VAR] = @prev_ruby_gate
    end

    def run_cli(extra_args)
      stdout = StringIO.new
      stderr = StringIO.new
      status = Cli.new(stdout: stdout, stderr: stderr).run([
        "--workflow", WORKFLOW,
        "--from-raw", RAW_FIXTURE,
        *extra_args
      ])
      [status, stdout.string, stderr.string]
    end

    def test_json_export_produces_canonical_envelope
      Dir.mktmpdir("freentonic-example") do |dir|
        out = File.join(dir, "out.json")
        status, _stdout, stderr = run_cli(["--export", "json", "--export-path", out])
        assert_equal 0, status, stderr
        wire = ::JSON.parse(File.read(out))

        assert_equal "0.1", wire["schema_version"]
        assert_equal 2, wire["accounts"].length
        assert_equal 4, wire["transactions"].length

        eur = wire["accounts"].find { |a| a["currency"] == "EUR" }
        assert_equal "Main Checking", eur["name"]
        assert_equal "1500.2", eur["balance"]["current"]
        assert_match(/\Aacc_[0-9a-f]{16}\z/, eur["id"])

        amazon = wire["transactions"].find { |t| t["raw_description"].include?("AMZN") }
        assert_match(/\Atxn_[0-9a-f]{16}\z/, amazon["id"])
        assert_equal "-45.2", amazon["amount"]
        assert_equal "posted", amazon["status"]
        assert_equal "Amazon", amazon["merchant"]["name"]
        assert_equal "AMZN Mktp ES", amazon["description"]  # cleaned
      end
    end

    def test_summary_is_auto_computed
      Dir.mktmpdir("freentonic-example") do |dir|
        out = File.join(dir, "out.json")
        status, _, stderr = run_cli(["--export", "json", "--export-path", out])
        assert_equal 0, status, stderr
        summary = ::JSON.parse(File.read(out))["summary"]

        assert_equal({ "accounts" => 2, "transactions" => 4,
                       "liabilities" => 0, "investments" => 0 }, summary["counts"])
        assert_equal "1142.3", summary["amounts_by_currency"]["EUR"]   # -45.20 + 1200 - 12.50
        assert_equal "-89.99", summary["amounts_by_currency"]["USD"]
        assert_equal "1500.2", summary["balances_by_currency"]["EUR"]
        assert_equal "830.45", summary["balances_by_currency"]["USD"]
        assert_equal "2026-04-15", summary["date_range"]["earliest"]
        assert_equal "2026-04-22", summary["date_range"]["latest"]
      end
    end

    def test_csv_export_flattens_with_account_hoist
      Dir.mktmpdir("freentonic-example") do |dir|
        out = File.join(dir, "out.csv")
        status, _, stderr = run_cli(["--export", "csv", "--export-path", out])
        assert_equal 0, status, stderr

        rows = ::CSV.read(out, headers: true)
        assert_equal 4, rows.length
        assert_includes rows.headers, "account_name"
        assert_includes rows.headers, "account_currency"
        assert_includes rows.headers, "account_institution"
        # column ordering: union sorted ASCII-ascending
        assert_equal rows.headers.sort, rows.headers

        eur_row = rows.find { |r| r["raw_description"]&.include?("AMZN") }
        assert_equal "Main Checking", eur_row["account_name"]
        assert_equal "EUR", eur_row["account_currency"]
        assert_equal "example_bank", eur_row["account_institution"]
      end
    end

    def test_jsonl_export_one_line_per_transaction
      Dir.mktmpdir("freentonic-example") do |dir|
        out = File.join(dir, "out.jsonl")
        status, _, stderr = run_cli(["--export", "jsonl", "--export-path", out])
        assert_equal 0, status, stderr

        lines = File.readlines(out).map(&:strip).reject(&:empty?)
        assert_equal 4, lines.length
        objs = lines.map { |l| ::JSON.parse(l) }
        amazon = objs.find { |o| o["raw_description"]&.include?("AMZN") }
        assert_equal "EUR", amazon["account_currency"]
      end
    end

    def test_deterministic_ids_stable_across_runs
      Dir.mktmpdir("freentonic-example") do |dir|
        out1 = File.join(dir, "run1.json")
        out2 = File.join(dir, "run2.json")
        run_cli(["--export", "json", "--export-path", out1])
        run_cli(["--export", "json", "--export-path", out2])
        ids1 = ::JSON.parse(File.read(out1))["transactions"].map { |t| t["id"] }
        ids2 = ::JSON.parse(File.read(out2))["transactions"].map { |t| t["id"] }
        assert_equal ids1, ids2, "transaction IDs must be deterministic across runs"
      end
    end
  end
end
