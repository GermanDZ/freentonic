# frozen_string_literal: true

require_relative "test_helper"
require "freentonic/debug_request_writer"
require "tmpdir"
require "json"

module Freentonic
  class DebugRequestWriterTest < Minitest::Test
    def sample_entries
      [
        {
          "request" => { "method" => "GET", "url" => "https://bank.example/api/accounts", "headers" => { "Cookie" => "sid=abc" } },
          "response" => { "status" => 200, "headers" => { "Content-Type" => "application/json" }, "body" => '{"accounts":[]}' },
          "timings" => { "started_at" => "2026-01-15T10:00:00+00:00", "duration_ms" => 120 }
        },
        {
          "request" => { "method" => "POST", "url" => "https://bank.example/api/movements", "headers" => {}, "body" => '{"from":"2026-01-01"}' },
          "response" => { "status" => 200, "headers" => { "Content-Type" => "application/json" }, "body" => '{"movements":[1,2]}' },
          "timings" => { "started_at" => "2026-01-15T10:00:01+00:00", "duration_ms" => 250 }
        }
      ]
    end

    def test_ndjson_roundtrip
      Dir.mktmpdir do |dir|
        path = File.join(dir, "capture.ndjson")
        writer = DebugRequestWriter.new(path: path, format: "ndjson")
        writer.write(sample_entries)

        lines = File.readlines(path).map(&:chomp)
        assert_equal 2, lines.size

        parsed = lines.map { |l| JSON.parse(l) }
        assert_equal "GET", parsed[0].dig("request", "method")
        assert_equal "POST", parsed[1].dig("request", "method")
        assert_equal 200, parsed[0].dig("response", "status")
        assert_equal '{"movements":[1,2]}', parsed[1].dig("response", "body")
      end
    end

    def test_ndjson_written_0600
      Dir.mktmpdir do |dir|
        path = File.join(dir, "capture.ndjson")
        DebugRequestWriter.new(path: path, format: "ndjson").write(sample_entries)
        assert_equal 0o600, File.stat(path).mode & 0o777,
          "captures hold cookies and response bodies — must be owner-only"
      end
    end

    def test_har_written_0600
      Dir.mktmpdir do |dir|
        path = File.join(dir, "capture.har")
        DebugRequestWriter.new(path: path, format: "har").write(sample_entries)
        assert_equal 0o600, File.stat(path).mode & 0o777,
          "captures hold cookies and response bodies — must be owner-only"
      end
    end

    def test_ndjson_empty_entries
      Dir.mktmpdir do |dir|
        path = File.join(dir, "empty.ndjson")
        writer = DebugRequestWriter.new(path: path, format: "ndjson")
        writer.write([])

        assert_equal "", File.read(path)
      end
    end

    def test_har_is_valid_structure
      Dir.mktmpdir do |dir|
        path = File.join(dir, "capture.har")
        writer = DebugRequestWriter.new(path: path, format: "har")
        writer.write(sample_entries)

        har = JSON.parse(File.read(path))
        assert_equal "1.2", har.dig("log", "version")
        assert_equal "freentonic", har.dig("log", "creator", "name")

        entries = har.dig("log", "entries")
        assert_equal 2, entries.size

        first = entries[0]
        assert_equal "GET", first.dig("request", "method")
        assert_equal "https://bank.example/api/accounts", first.dig("request", "url")
        assert_equal 200, first.dig("response", "status")
        assert_equal '{"accounts":[]}', first.dig("response", "content", "text")
        assert_equal "2026-01-15T10:00:00+00:00", first["startedDateTime"]

        second = entries[1]
        assert_equal "POST", second.dig("request", "method")
        assert_includes second.dig("request").keys, "postData"
        assert_equal '{"from":"2026-01-01"}', second.dig("request", "postData", "text")
      end
    end

    def test_har_headers_are_name_value_pairs
      Dir.mktmpdir do |dir|
        path = File.join(dir, "capture.har")
        writer = DebugRequestWriter.new(path: path, format: "har")
        writer.write(sample_entries)

        har = JSON.parse(File.read(path))
        req_headers = har.dig("log", "entries", 0, "request", "headers")
        assert_kind_of Array, req_headers
        assert(req_headers.any? { |h| h["name"] == "Cookie" && h["value"] == "sid=abc" })
      end
    end

    def test_rejects_path_containing_freentonic_providers
      err = assert_raises(UserError) do
        DebugRequestWriter.new(path: "/home/user/freentonic-providers/acme/capture.json")
      end
      assert_includes err.message, "freentonic-providers"
    end

    def test_rejects_path_inside_git_repo
      # We're running inside the freentonic repo, so a path inside it should be rejected
      err = assert_raises(UserError) do
        DebugRequestWriter.new(path: File.join(Dir.pwd, "tmp_capture.json"))
      end
      assert_includes err.message, "git repo"
    end

    def test_accepts_path_in_tmp
      Dir.mktmpdir do |dir|
        path = File.join(dir, "capture.ndjson")
        writer = DebugRequestWriter.new(path: path, format: "ndjson")
        writer.write([])
        assert File.exist?(path)
      end
    end

    def test_unknown_format_raises
      Dir.mktmpdir do |dir|
        path = File.join(dir, "capture.xml")
        err = assert_raises(UserError) do
          writer = DebugRequestWriter.new(path: path, format: "xml")
          writer.write([])
        end
        assert_includes err.message, "unknown format"
      end
    end
  end
end
