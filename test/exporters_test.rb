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

    # csv/jsonl require CanonicalPayload input and render rows inline.

    def canonical_payload
      Canonical::CanonicalPayload.new(
        accounts: [
          Canonical::Account.new(id: "acc_eur", institution: "bbva",
                                 name: "Alice", currency: "EUR")
        ],
        transactions: [
          Canonical::Transaction.new(id: "txn_1", account_id: "acc_eur",
                                     amount: "10.00", currency: "EUR",
                                     description: "Coffee"),
          Canonical::Transaction.new(id: "txn_2", account_id: "acc_eur",
                                     amount: "-5.00", currency: "EUR",
                                     description: "Refund")
        ],
        summary: nil
      )
    end

    def test_jsonl_exporter_writes_one_canonical_transaction_per_line
      Tempfile.open(["freentonic-jsonl", ".jsonl"]) do |tmp|
        Exporters::Jsonl.new(path: tmp.path).write(canonical_payload)
        lines = File.readlines(tmp.path).map { |l| ::JSON.parse(l) }
        assert_equal 2, lines.size
        assert_equal "txn_1", lines.first["id"]
        assert_equal "Alice", lines.first["account_name"]
        assert_equal "EUR", lines.first["account_currency"]
      end
    end

    def test_csv_exporter_writes_canonical_transactions_as_rows
      Tempfile.open(["freentonic-csv", ".csv"]) do |tmp|
        Exporters::Csv.new(path: tmp.path).write(canonical_payload)
        rows = ::CSV.read(tmp.path, headers: true)
        assert_equal 2, rows.size
        assert_includes rows.headers, "account_name"
        assert_includes rows.headers, "id"
        assert_equal "txn_1", rows.first["id"]
        assert_equal "10.0", rows.first["amount"]
      end
    end

    def test_csv_exporter_neutralizes_formula_injection_but_keeps_numbers
      payload = Canonical::CanonicalPayload.new(
        accounts: [
          Canonical::Account.new(id: "a", institution: "x",
                                 name: '=HYPERLINK("http://evil")', currency: "EUR")
        ],
        transactions: [
          Canonical::Transaction.new(id: "t1", account_id: "a", amount: "-5.00",
                                     currency: "EUR", description: "=cmd|' /C calc'!A1"),
          Canonical::Transaction.new(id: "t2", account_id: "a", amount: "10.00",
                                     currency: "EUR", description: "@SUM(A1:A9)")
        ],
        summary: nil
      )
      Tempfile.open(["freentonic-csv", ".csv"]) do |tmp|
        Exporters::Csv.new(path: tmp.path).write(payload)
        rows = ::CSV.read(tmp.path, headers: true)
        # Attacker-influenceable text starting with a formula trigger is quoted.
        assert_equal "'=cmd|' /C calc'!A1", rows[0]["description"]
        assert_equal "'@SUM(A1:A9)", rows[1]["description"]
        assert_equal '\'=HYPERLINK("http://evil")', rows[0]["account_name"]
        # Negative amounts stay numeric — not mangled into text.
        assert_equal "-5.0", rows[0]["amount"]
      end
    end

    def test_csv_exporter_rejects_non_canonical_payload
      err = assert_raises(UserError) do
        Tempfile.open(["freentonic-csv", ".csv"]) do |tmp|
          Exporters::Csv.new(path: tmp.path).write(sample_payload)
        end
      end
      assert_match(/CanonicalPayload/, err.message)
      assert_match(/canonical-data-model/, err.message)
    end

    def test_jsonl_exporter_rejects_non_canonical_payload
      err = assert_raises(UserError) do
        Tempfile.open(["freentonic-jsonl", ".jsonl"]) do |tmp|
          Exporters::Jsonl.new(path: tmp.path).write(sample_payload)
        end
      end
      assert_match(/CanonicalPayload/, err.message)
      assert_match(/canonical-data-model/, err.message)
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
        original = $stdout
        $stdout = StringIO.new
        begin
          result = Exporters::Http.new(url: "https://example.test/push", token: "tok-abc").write(sample_payload)
          assert_equal true, result["ok"]
          assert_equal "Bearer tok-abc", captured[:auth]
          assert_equal "application/json", captured[:ct]
          assert_equal "test", ::JSON.parse(captured[:body])["source_tag"]
          assert_match(
            %r{POST https://example\.test/push → 200 in \d+ms},
            $stdout.string,
            "expected a one-line success log so the run doesn't look hung"
          )
        ensure
          $stdout = original
        end
      end
    end

    def test_http_exporter_does_not_log_success_line_on_error
      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) { |_req| FakeResp.new("500", "boom") }

      with_net_http_new(fake_http) do
        original = $stdout
        $stdout = StringIO.new
        begin
          assert_raises(ExportError) do
            Exporters::Http.new(url: "https://example.test/push", token: "t", retries: 0).write(sample_payload)
          end
          refute_match(
            /→/,
            $stdout.string,
            "success line should not appear when the receiver rejected the push"
          )
        ensure
          $stdout = original
        end
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
          Exporters::Http.new(url: "https://example.test/push", retries: 0).write(sample_payload)
        end
        assert_includes err.message, "HTTP 500"
      end
    end

    def test_http_exporter_refuses_cleartext_with_token
      err = assert_raises(UserError) do
        silence_stdout do
          Exporters::Http.new(url: "http://example.test/push", token: "tok-abc").write(sample_payload)
        end
      end
      assert_includes err.message, "cleartext"
      assert_includes err.message, "https://"
    end

    def test_http_exporter_refuses_cleartext_token_to_public_ip
      err = assert_raises(UserError) do
        silence_stdout do
          Exporters::Http.new(url: "http://93.184.216.34/push", token: "tok-abc").write(sample_payload)
        end
      end
      assert_includes err.message, "cleartext"
    end

    # A same-host / private-network receiver (TLS terminated upstream) is
    # inside the trust boundary, so cleartext + token is allowed there.
    def test_http_exporter_allows_cleartext_token_to_loopback
      captured = nil
      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) { |req| captured = req["Authorization"]; FakeResp.new("200", "{}") }

      with_net_http_new(fake_http) do
        silence_stdout do
          Exporters::Http.new(url: "http://127.0.0.1:3000/push", token: "tok-abc").write(sample_payload)
        end
      end
      assert_equal "Bearer tok-abc", captured, "token should still be sent to a loopback receiver"
    end

    def test_http_exporter_allows_cleartext_token_to_private_host
      captured = nil
      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) { |req| captured = req["Authorization"]; FakeResp.new("200", "{}") }

      with_net_http_new(fake_http) do
        silence_stdout do
          Exporters::Http.new(url: "http://10.10.40.5/push", token: "tok-abc").write(sample_payload)
        end
      end
      assert_equal "Bearer tok-abc", captured
    end

    def test_http_exporter_warns_on_cleartext_without_token
      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) { |_req| FakeResp.new("200", "{}") }

      with_net_http_new(fake_http) do
        original = $stdout
        $stdout = StringIO.new
        begin
          Exporters::Http.new(url: "http://example.test/push").write(sample_payload)
          assert_match(/cleartext/, $stdout.string)
        ensure
          $stdout = original
        end
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
          Exporters::Http.new(url: "https://example.test/push", token: "bad").write(sample_payload)
        end
        assert_includes err.message, "unauthorized"
      end
    end

    # meta.freentonic_run_id injection — lets an HTTP receiver correlate its
    # ingest with the originating /invoke. Only applies when the invoke
    # server has set FREENTONIC_RUN_ID on the child process.

    def build_capturing_http
      captured = Object.new
      captured.instance_variable_set(:@body, nil)
      def captured.body; @body; end
      def captured.body=(v); @body = v; end

      fake_http = Object.new
      fake_http.define_singleton_method(:use_ssl=) { |_| }
      fake_http.define_singleton_method(:open_timeout=) { |_| }
      fake_http.define_singleton_method(:read_timeout=) { |_| }
      fake_http.define_singleton_method(:request) do |req|
        captured.body = req.body
        FakeResp.new("200", "{}")
      end
      [captured, fake_http]
    end

    def with_env(name, value)
      original = ENV[name]
      ENV[name] = value
      yield
    ensure
      ENV[name] = original
    end

    def silence_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = original
    end

    def test_http_exporter_injects_run_id_meta_when_env_set
      captured, fake_http = build_capturing_http
      with_net_http_new(fake_http) do
        with_env("FREENTONIC_RUN_ID", "run-abc-123") do
          silence_stdout do
            Exporters::Http.new(url: "https://example.test/push", token: "tok").write(sample_payload)
          end
        end
      end
      sent = ::JSON.parse(captured.body)
      assert_equal "run-abc-123", sent.dig("meta", "freentonic_run_id")
      assert_equal "test", sent["source_tag"],
        "original payload keys must survive the merge"
    end

    def test_http_exporter_merges_into_existing_meta
      captured, fake_http = build_capturing_http
      payload = sample_payload.merge("meta" => { "workflow_version" => "1.2.3" })
      with_net_http_new(fake_http) do
        with_env("FREENTONIC_RUN_ID", "run-abc-123") do
          silence_stdout do
            Exporters::Http.new(url: "https://example.test/push", token: "tok").write(payload)
          end
        end
      end
      sent = ::JSON.parse(captured.body)
      assert_equal "run-abc-123", sent["meta"]["freentonic_run_id"]
      assert_equal "1.2.3", sent["meta"]["workflow_version"]
    end

    def test_http_exporter_does_not_clobber_workflow_supplied_run_id
      captured, fake_http = build_capturing_http
      payload = sample_payload.merge("meta" => { "freentonic_run_id" => "explicit-from-workflow" })
      with_net_http_new(fake_http) do
        with_env("FREENTONIC_RUN_ID", "run-abc-123") do
          silence_stdout do
            Exporters::Http.new(url: "https://example.test/push", token: "tok").write(payload)
          end
        end
      end
      sent = ::JSON.parse(captured.body)
      assert_equal "explicit-from-workflow", sent["meta"]["freentonic_run_id"]
    end

    def test_http_exporter_does_not_inject_when_env_unset
      captured, fake_http = build_capturing_http
      with_net_http_new(fake_http) do
        with_env("FREENTONIC_RUN_ID", nil) do
          silence_stdout do
            Exporters::Http.new(url: "https://example.test/push", token: "tok").write(sample_payload)
          end
        end
      end
      sent = ::JSON.parse(captured.body)
      refute sent.key?("meta"), "unexpected meta key when FREENTONIC_RUN_ID is absent"
    end

    # --- retry with backoff (#18) ---

    # Fake Net::HTTP whose #request replays a scripted sequence of outcomes:
    # a FakeResp is returned, an Exception instance is raised. Records how
    # many times it was called.
    def scripted_http(*outcomes)
      calls = []
      http = Object.new
      http.define_singleton_method(:use_ssl=) { |_| }
      http.define_singleton_method(:open_timeout=) { |_| }
      http.define_singleton_method(:read_timeout=) { |_| }
      http.define_singleton_method(:request) do |_req|
        outcome = outcomes[calls.size] || outcomes.last
        calls << outcome
        raise outcome if outcome.is_a?(Exception)
        outcome
      end
      http.define_singleton_method(:call_count) { calls.size }
      http
    end

    def test_http_exporter_retries_transient_connection_refused_then_succeeds
      http = scripted_http(Errno::ECONNREFUSED.new, FakeResp.new("200", "{}"))
      out = StringIO.new
      with_net_http_new(http) do
        result = Exporters::Http.new(
          url: "https://example.test/push", retry_base_delay: 0, io: out
        ).write(sample_payload)
        assert_equal({}, result)
      end
      assert_equal 2, http.call_count, "should retry once then succeed"
      assert_match(/retry 1\/2/, out.string)
      assert_match(%r{→ 200}, out.string, "success line still emitted after a retry")
    end

    def test_http_exporter_retries_5xx_then_succeeds
      http = scripted_http(FakeResp.new("503", "busy"), FakeResp.new("200", '{"ok":true}'))
      out = StringIO.new
      with_net_http_new(http) do
        result = Exporters::Http.new(
          url: "https://example.test/push", retry_base_delay: 0, io: out
        ).write(sample_payload)
        assert_equal true, result["ok"]
      end
      assert_equal 2, http.call_count
      assert_match(/HTTP 503 — retry 1\/2/, out.string)
    end

    def test_http_exporter_gives_up_after_exhausting_retries_on_transport
      http = scripted_http(Errno::ECONNREFUSED.new)
      with_net_http_new(http) do
        err = assert_raises(ExportError) do
          Exporters::Http.new(
            url: "https://example.test/push", retry_base_delay: 0, io: StringIO.new
          ).write(sample_payload)
        end
        assert_includes err.message, "connection refused"
        assert_includes err.message, "after 2 retries"
      end
      assert_equal 3, http.call_count, "1 initial attempt + 2 retries"
    end

    def test_http_exporter_does_not_retry_dns_failure
      http = scripted_http(SocketError.new("getaddrinfo: nodename nor servname"))
      with_net_http_new(http) do
        err = assert_raises(ExportError) do
          Exporters::Http.new(
            url: "https://example.test/push", retry_base_delay: 0, io: StringIO.new
          ).write(sample_payload)
        end
        assert_includes err.message, "could not resolve"
      end
      assert_equal 1, http.call_count, "DNS failures are permanent — no retry"
    end

    def test_http_exporter_does_not_retry_4xx
      http = scripted_http(FakeResp.new("404", "nope"))
      with_net_http_new(http) do
        assert_raises(ExportError) do
          Exporters::Http.new(
            url: "https://example.test/push", retry_base_delay: 0, io: StringIO.new
          ).write(sample_payload)
        end
      end
      assert_equal 1, http.call_count, "4xx is a permanent client error — no retry"
    end

    def test_http_exporter_progress_goes_to_injected_io_not_global_stdout
      http = scripted_http(FakeResp.new("200", "{}"))
      out = StringIO.new
      with_net_http_new(http) do
        silence_stdout do
          Exporters::Http.new(url: "https://example.test/push", io: out).write(sample_payload)
          assert_empty $stdout.string, "nothing should leak to global $stdout"
        end
      end
      assert_match(%r{→ 200}, out.string, "progress line goes to the injected io")
    end
  end
end
