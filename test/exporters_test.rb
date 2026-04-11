# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tempfile"
require "json"
require "csv"
require "net/http"

module Freentonic
  class ExportersTest < Minitest::Test
    def sample_payload
      {
        "source_tag" => "test",
        "accounts" => [
          {
            "external_id" => "a1",
            "name" => "Alice",
            "movements" => [
              { "dedup_key" => "m1", "amount_cents" => 1000, "description" => "Coffee" },
              { "dedup_key" => "m2", "amount_cents" => -500, "description" => "Refund" }
            ]
          }
        ]
      }
    end

    def test_json_exporter_writes_pretty_json_to_file
      Tempfile.open(["freentonic-json", ".json"]) do |tmp|
        Exporters::Json.new(path: tmp.path).write(sample_payload)
        parsed = ::JSON.parse(File.read(tmp.path))
        assert_equal "test", parsed["source_tag"]
        assert_equal 1, parsed["accounts"].size
      end
    end

    def test_jsonl_exporter_flattens_nested_select
      Tempfile.open(["freentonic-jsonl", ".jsonl"]) do |tmp|
        Exporters::Jsonl.new(path: tmp.path, select: "accounts.movements").write(sample_payload)
        lines = File.readlines(tmp.path).map { |l| ::JSON.parse(l) }
        assert_equal 2, lines.size
        assert_equal "m1", lines.first["dedup_key"]
        # parent fields are hoisted with "account_" prefix (accounts → account + "_")
        assert_equal "a1", lines.first["account_external_id"]
        assert_equal "Alice", lines.first["account_name"]
      end
    end

    def test_csv_exporter_produces_rows_from_nested_select
      Tempfile.open(["freentonic-csv", ".csv"]) do |tmp|
        Exporters::Csv.new(path: tmp.path, select: "accounts.movements").write(sample_payload)
        rows = ::CSV.read(tmp.path, headers: true)
        assert_equal 2, rows.size
        assert_includes rows.headers, "account_external_id"
        assert_includes rows.headers, "dedup_key"
        assert_equal "m1", rows.first["dedup_key"]
      end
    end

    # Minimal fake Net::HTTP response that mimics the bits the exporter reads.
    FakeResp = Struct.new(:code, :body) do
      def [](_key); nil; end
    end

    def test_http_exporter_posts_json_and_returns_parsed_body
      captured = nil
      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) do |req|
        captured = { body: req.body, auth: req["Authorization"], ct: req["Content-Type"] }
        FakeResp.new("200", '{"ok":true,"counts":{"rows":2}}')
      end

      with_net_http_new(fake_http) do
        result = Exporters::Http.new(url: "http://example.test/push", token: "tok-abc").write(sample_payload)
        assert_equal true, result["ok"]
        assert_equal "Bearer tok-abc", captured[:auth]
        assert_equal "application/json", captured[:ct]
        assert_equal "test", ::JSON.parse(captured[:body])["source_tag"]
      end
    end

    def test_http_exporter_raises_export_error_on_non_2xx
      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) { |_req| FakeResp.new("500", "boom") }

      with_net_http_new(fake_http) do
        err = assert_raises(ExportError) do
          Exporters::Http.new(url: "http://example.test/push").write(sample_payload)
        end
        assert_includes err.message, "HTTP 500"
      end
    end

    def test_http_exporter_rejects_bare_host_url_with_hint
      err = assert_raises(UserError) do
        Exporters::Http.new(url: "http://localhost:3000").write(sample_payload)
      end
      assert_includes err.message, "must include the full path"
      assert_includes err.message, "/your/endpoint/path"
    end

    def test_http_exporter_raises_unauthorized_for_401
      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) { |_req| FakeResp.new("401", "nope") }

      with_net_http_new(fake_http) do
        err = assert_raises(ExportError) do
          Exporters::Http.new(url: "http://example.test/push", token: "bad").write(sample_payload)
        end
        assert_includes err.message, "unauthorized"
      end
    end
  end
end
