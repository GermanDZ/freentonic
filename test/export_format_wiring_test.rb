# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tempfile"
require "tmpdir"
require "json"
require "net/http"

module Freentonic
  # PR 3 wiring: --export-format flag, Exporters::Base#resolve_formatter,
  # and the http/json exporters consuming the formatter.
  class ExportFormatWiringTest < Minitest::Test
    # ---------- CLI parsing ----------

    def test_export_format_attaches_to_last_exporter
      opts = Cli.new(stderr: StringIO.new).send(:parse,
        ["--workflow", "x.yml", "--export", "http", "--export-url", "http://e/p",
         "--export-format", "canonical"])
      assert_equal :canonical, opts[:exporters].last[:options][:format]
    end

    def test_export_format_unknown_name_raises
      err = assert_raises(UserError) do
        Cli.new(stderr: StringIO.new).send(:parse,
          ["--workflow", "x.yml", "--export", "http", "--export-format", "nope"])
      end
      assert_match(/unknown format/, err.message)
    end

    def test_export_format_before_export_raises
      err = assert_raises(UserError) do
        Cli.new(stderr: StringIO.new).send(:parse,
          ["--workflow", "x.yml", "--export-format", "canonical"])
      end
      assert_match(/before --export NAME/, err.message)
    end

    def test_export_format_attaches_per_group
      opts = Cli.new(stderr: StringIO.new).send(:parse,
        ["--workflow", "x.yml",
         "--export", "json", "--export-format", "canonical",
         "--export", "http", "--export-url", "http://e/p", "--export-format", "csv_transactions"])
      assert_equal :canonical, opts[:exporters][0][:options][:format]
      assert_equal :csv_transactions, opts[:exporters][1][:options][:format]
    end

    # ---------- Exporters::Base ----------

    def test_default_format_is_canonical
      assert_equal :canonical, Exporters::Json.new.send(:default_format)
      assert_equal :canonical, Exporters::Http.new.send(:default_format)
    end

    def test_resolve_formatter_uses_options_override
      f = Exporters::Json.new(format: :csv_transactions).send(:resolve_formatter)
      assert_instance_of ::Freentonic::Formatters::CsvTransactions, f
    end

    def test_resolve_formatter_falls_back_to_default
      f = Exporters::Json.new.send(:resolve_formatter)
      assert_instance_of ::Freentonic::Formatters::Canonical, f
    end

    # ---------- JSON exporter through formatter ----------

    def legacy_payload
      { "source_tag" => "test", "rows" => [{ "id" => 1 }] }
    end

    def test_json_exporter_canonical_default_preserves_legacy_hash_payload
      Tempfile.open(["wire", ".json"]) do |tmp|
        Exporters::Json.new(path: tmp.path).write(legacy_payload)
        assert_equal legacy_payload, ::JSON.parse(File.read(tmp.path))
      end
    end

    def test_json_exporter_string_formatter_writes_bytes_verbatim
      string_formatter = Class.new(Formatters::Base) do
        def call(_payload); "hello,world\n1,2\n"; end
        def content_type; "text/csv"; end
      end
      Formatters.register(:string_test_csv, string_formatter)
      begin
        Tempfile.open(["wire", ".csv"]) do |tmp|
          Exporters::Json.new(path: tmp.path, format: :string_test_csv).write({})
          assert_equal "hello,world\n1,2\n", File.read(tmp.path)
        end
      ensure
        Formatters.instance_variable_get(:@registry).delete(:string_test_csv)
      end
    end

    def test_json_exporter_with_canonical_payload_emits_envelope
      payload = Canonical::CanonicalPayload.new(
        accounts: [Canonical::Account.new(id: "acc_1", currency: "EUR")],
        summary: nil
      )
      Tempfile.open(["wire", ".json"]) do |tmp|
        Exporters::Json.new(path: tmp.path).write(payload)
        wire = ::JSON.parse(File.read(tmp.path))
        assert_equal "0.1", wire["schema_version"]
        assert_equal 1, wire["accounts"].length
      end
    end

    # ---------- HTTP exporter through formatter ----------

    FakeResp = Struct.new(:code, :body) do
      def [](_key); nil; end
    end

    def build_capturing_http
      captured = { body: nil, ct: nil }
      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) do |req|
        captured[:body] = req.body
        captured[:ct] = req["Content-Type"]
        FakeResp.new("200", "{}")
      end
      [captured, fake_http]
    end

    def silence_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = original
    end

    def test_http_exporter_canonical_default_preserves_legacy_payload
      captured, fake = build_capturing_http
      with_net_http_new(fake) do
        silence_stdout do
          Exporters::Http.new(url: "http://e.test/p").write(legacy_payload)
        end
      end
      assert_equal "application/json", captured[:ct]
      assert_equal legacy_payload, ::JSON.parse(captured[:body])
    end

    def test_http_exporter_canonical_default_with_canonical_payload
      payload = Canonical::CanonicalPayload.new(
        transactions: [Canonical::Transaction.new(id: "t1", account_id: "a1",
                                                   amount: "10", currency: "EUR")],
        summary: nil
      )
      captured, fake = build_capturing_http
      with_net_http_new(fake) do
        silence_stdout do
          Exporters::Http.new(url: "http://e.test/p").write(payload)
        end
      end
      assert_equal "application/json", captured[:ct]
      wire = ::JSON.parse(captured[:body])
      assert_equal "0.1", wire["schema_version"]
      assert_equal "10.0", wire["transactions"].first["amount"]
    end

    def test_http_exporter_string_formatter_sets_content_type_and_skips_meta_merge
      string_formatter = Class.new(Formatters::Base) do
        def call(_payload); "<ofx>stub</ofx>"; end
        def content_type; "application/x-ofx"; end
      end
      Formatters.register(:ofx_stub, string_formatter)
      begin
        captured, fake = build_capturing_http
        with_net_http_new(fake) do
          silence_stdout do
            ENV["FREENTONIC_RUN_ID"] = "should-not-leak-into-string-bodies"
            Exporters::Http.new(url: "http://e.test/p", format: :ofx_stub).write({})
            ENV.delete("FREENTONIC_RUN_ID")
          end
        end
        assert_equal "application/x-ofx", captured[:ct]
        assert_equal "<ofx>stub</ofx>", captured[:body]
      ensure
        Formatters.instance_variable_get(:@registry).delete(:ofx_stub)
        ENV.delete("FREENTONIC_RUN_ID")
      end
    end

    def test_http_exporter_explicit_content_type_overrides_formatter
      captured, fake = build_capturing_http
      with_net_http_new(fake) do
        silence_stdout do
          Exporters::Http.new(url: "http://e.test/p",
                              content_type: "application/vnd.custom+json").write(legacy_payload)
        end
      end
      assert_equal "application/vnd.custom+json", captured[:ct]
    end

    def test_http_exporter_run_id_meta_merge_still_applies_to_hash_outputs
      captured, fake = build_capturing_http
      with_net_http_new(fake) do
        silence_stdout do
          ENV["FREENTONIC_RUN_ID"] = "run-xyz"
          Exporters::Http.new(url: "http://e.test/p").write(legacy_payload)
          ENV.delete("FREENTONIC_RUN_ID")
        end
      end
      wire = ::JSON.parse(captured[:body])
      assert_equal "run-xyz", wire["meta"]["freentonic_run_id"]
    ensure
      ENV.delete("FREENTONIC_RUN_ID")
    end
  end
end
