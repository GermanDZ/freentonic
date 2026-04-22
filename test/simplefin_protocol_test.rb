# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "net/http"
require "json"
require "base64"
require "socket"
require "freentonic/invoke_server"
require "freentonic/simplefin/feature"
require "freentonic/simplefin/router"

module Freentonic
  module Simplefin
    # End-to-end protocol tests. Spins up an InvokeServer with a real
    # Simplefin router, but stubs the sync queue so we never spawn Chrome.
    class ProtocolTest < Minitest::Test
      # Fake runner — InvokeServer uses it for workflows_dir + chrome_profile_root.
      FakeRunner = Struct.new(:runs_dir, :workflows_dir, :chrome_profile_root)

      # Stand-in for SyncQueue. Records every enqueue call and exposes the
      # list for assertions. Matches the #enqueue / #pending_keys / #active_key
      # surface the router expects.
      class RecordingQueue
        attr_reader :enqueued
        def initialize; @enqueued = []; end
        def enqueue(key, headed: false, trigger: "auto")
          @enqueued << [key, headed, trigger]; :enqueued
        end
        def pending_keys; @enqueued.map(&:first); end
        def active_key; nil; end
      end

      def setup
        @root          = Dir.mktmpdir("simplefin-proto-")
        @runs          = Dir.mktmpdir("simplefin-runs-")
        @workflows_dir = Dir.mktmpdir("simplefin-wf-")
        # Create a minimal fake workflow so create-profile validation passes.
        @workflow_name = "acme/workflow.yml"
        FileUtils.mkdir_p(File.join(@workflows_dir, "acme"))
        File.write(File.join(@workflows_dir, @workflow_name), <<~YAML)
          source:
            credentials:
              - USER_DNI
              - USER_PIN
        YAML

        @master_key_b64 = Crypto.generate_master_key_b64
        ENV["FREENTONIC_SIMPLEFIN_ENABLED"] = "1"
        ENV["FREENTONIC_SECRETS_KEY"]       = @master_key_b64
        ENV["FREENTONIC_ADMIN_PASSWORD"]    = "admin-pw"
        ENV["FREENTONIC_PUBLIC_URL"]        = "http://freentonic.example"
        ENV["FREENTONIC_SIMPLEFIN_ROOT"]    = @root

        @feature = Feature.from_env
        @feature.recover_on_boot!
        @queue = RecordingQueue.new
        @feature.install_queue(@queue)

        ui_dir = File.expand_path("../lib/freentonic/simplefin/ui", __dir__)
        @router = Router.new(feature: @feature,
                             workflows_dir: @workflows_dir,
                             runs_dir: @runs,
                             asset_dir: ui_dir)

        @runner = FakeRunner.new(@runs, @workflows_dir, Dir.mktmpdir("chrome-"))
        @port   = find_free_port
        @server = InvokeServer.new(
          runner:           @runner,
          listen_addr:      "127.0.0.1",
          listen_port:      @port,
          logger:           nil,
          simplefin_router: @router
        )
        @thread = Thread.new { @server.start }
        wait_for_server_up
      end

      def teardown
        @server.shutdown
        @thread.join(3)
        FileUtils.rm_rf(@root)
        FileUtils.rm_rf(@runs)
        FileUtils.rm_rf(@workflows_dir)
        %w[FREENTONIC_SIMPLEFIN_ENABLED FREENTONIC_SECRETS_KEY FREENTONIC_ADMIN_PASSWORD
           FREENTONIC_PUBLIC_URL FREENTONIC_SIMPLEFIN_ROOT].each { |k| ENV.delete(k) }
      end

      # ── helpers ────────────────────────────────────────────

      def find_free_port
        s = TCPServer.new("127.0.0.1", 0); port = s.addr[1]; s.close; port
      end

      def wait_for_server_up(timeout: 5)
        deadline = Time.now + timeout
        while Time.now < deadline
          begin
            TCPSocket.new("127.0.0.1", @port).close
            return
          rescue StandardError
            sleep 0.02
          end
        end
        raise "server did not come up"
      end

      def req(method, path, body: nil, headers: {})
        uri = URI("http://127.0.0.1:#{@port}#{path}")
        klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post,
                  "PATCH" => Net::HTTP::Patch, "DELETE" => Net::HTTP::Delete }[method]
        r = klass.new(uri.request_uri)
        headers.each { |k, v| r[k] = v }
        if body
          r["Content-Type"] = "application/json" unless r["Content-Type"]
          r.body = body.is_a?(String) ? body : JSON.generate(body)
        end
        Net::HTTP.start(uri.host, uri.port) { |h| h.request(r) }
      end

      def admin(headers = {})
        { "Authorization" => "Bearer admin-pw" }.merge(headers)
      end

      # ── Admin API: profile lifecycle ────────────────────────

      def test_admin_create_profile
        res = req("POST", "/admin/api/profiles", body: {
          profile_key: "acme",
          workflow:    @workflow_name,
          display_name: "Acme"
        }, headers: admin)
        assert_equal "200", res.code
        body = JSON.parse(res.body)
        assert_equal "acme", body["profile"]["profile_key"]
      end

      def test_admin_api_requires_bearer
        res = req("GET", "/admin/api/profiles")
        assert_equal "401", res.code
      end

      def test_admin_workflows_lists_declared_secrets
        res = req("GET", "/admin/api/workflows", headers: admin)
        assert_equal "200", res.code
        body = JSON.parse(res.body)
        wf = body["workflows"].find { |w| w["workflow"] == @workflow_name }
        assert wf
        assert_equal %w[USER_DNI USER_PIN], wf["secrets"]
      end

      def test_admin_credentials_encrypted_on_disk
        req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
        req("POST", "/admin/api/profiles/acme/credentials",
            body: { secrets: { "USER_DNI" => "12345", "USER_PIN" => "9999" } },
            headers: admin)
        raw = File.read(Paths.profile_path("acme", @root))
        refute_includes raw, "12345"
        refute_includes raw, "9999"
      end

      # ── Protocol: claim + access URL + accounts ─────────────

      def test_setup_token_can_be_claimed_once
        req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
        res = req("POST", "/admin/api/profiles/acme/setup-token", headers: admin)
        token = JSON.parse(res.body)["setup_token"]
        claim_url = Base64.strict_decode64(token)
        path = URI(claim_url).path

        first = req("POST", path)
        assert_equal "200", first.code
        assert_match(%r{http://[^@]+@freentonic.example/simplefin/accounts/acme}, first.body)

        # Second attempt is rejected.
        second = req("POST", path)
        assert_equal "403", second.code
      end

      def test_accounts_enqueues_when_idle_and_returns_empty_notice
        provision_profile_with_access_url("acme")

        url, user, password = current_access_url("acme")
        res = req("GET", url, headers: basic_auth(user, password))

        assert_equal "200", res.code
        body = JSON.parse(res.body)
        assert_equal [], body["accounts"]
        assert_match(/scheduled/i, body["errors"].first)
        assert_equal ["acme"], @queue.enqueued.map(&:first)
      end

      def test_accounts_rejects_bad_password
        provision_profile_with_access_url("acme")
        url, user, _ = current_access_url("acme")
        res = req("GET", url, headers: basic_auth(user, "wrong"))
        assert_equal "401", res.code
      end

      def test_accounts_returns_ready_payload_and_unlinks_cache
        provision_profile_with_access_url("acme")
        # Simulate a successful sync having written a cache payload.
        envelope = {
          "accounts" => [{
            "id" => "x", "currency" => "EUR", "balance" => "10.00",
            "balance-date" => Time.now.to_i, "transactions" => []
          }],
          "errors" => []
        }
        @feature.cache_store.write("acme", envelope)
        @feature.state_store.force_state("acme", "ready")

        url, user, password = current_access_url("acme")
        res = req("GET", url, headers: basic_auth(user, password))
        body = JSON.parse(res.body)
        assert_equal 1, body["accounts"].size
        assert_equal "idle", @feature.state_store.read("acme")["state"]
        refute @feature.cache_store.exists?("acme")
      end

      def test_accounts_rate_limits_auto_enqueue
        provision_profile_with_access_url("acme")
        url, user, password = current_access_url("acme")
        headers = basic_auth(user, password)

        3.times { req("GET", url, headers: headers) }
        assert_equal 1, @queue.enqueued.size,
          "repeated GET /accounts within the rate-limit window must enqueue only once"
      end

      def test_accounts_needs_reauth_does_not_enqueue
        provision_profile_with_access_url("acme")
        @feature.state_store.force_state("acme", "needs_reauth", "last_error" => "session expired")

        url, user, password = current_access_url("acme")
        res = req("GET", url, headers: basic_auth(user, password))
        body = JSON.parse(res.body)
        assert_match(/re-authentication required/i, body["errors"].first)
        assert_empty @queue.enqueued
      end

      # ── Run log proxy ──────────────────────────────────────

      def test_admin_api_serves_run_log
        req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
        @feature.run_log.record("acme", run_id: "run_1", outcome: "ready",
                                exit_code: 0, message: "ok")
        FileUtils.mkdir_p(File.join(@runs, "run_1"))
        File.write(File.join(@runs, "run_1", "log"), "hello from the invoke child\n")

        res = req("GET", "/admin/api/profiles/acme/runs/run_1/log", headers: admin)
        assert_equal "200", res.code
        body = JSON.parse(res.body)
        assert_equal "run_1", body["run_id"]
        assert_equal "hello from the invoke child\n", body["log"]
      end

      def test_admin_api_run_log_rejects_bad_run_id
        req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
        res = req("GET", "/admin/api/profiles/acme/runs/..%2Fescape/log", headers: admin)
        assert_equal "404", res.code
      end

      def test_admin_api_run_log_404_when_missing
        req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
        res = req("GET", "/admin/api/profiles/acme/runs/never/log", headers: admin)
        assert_equal "404", res.code
      end

      # ── Admin UI: login cookie drives the API ───────────────

      def test_admin_login_sets_session_cookie
        res = req("POST", "/admin/login", body: "password=admin-pw",
                  headers: { "Content-Type" => "application/x-www-form-urlencoded" })
        assert_equal "303", res.code
        assert_match(/freentonic_simplefin_session=/, res["set-cookie"])
      end

      def test_admin_api_accepts_valid_session_cookie
        login = req("POST", "/admin/login", body: "password=admin-pw",
                    headers: { "Content-Type" => "application/x-www-form-urlencoded" })
        cookie = login["set-cookie"].split(";").first
        res = req("GET", "/admin/api/profiles", headers: { "Cookie" => cookie })
        assert_equal "200", res.code
      end

      # ── Metrics + scheduling + hidden accounts ──────────────

      def test_metrics_endpoint_aggregates
        provision_profile_with_access_url("acme")
        @feature.state_store.force_state("acme", "ready",
          "last_synced_at" => Time.now.utc.iso8601, "last_error" => nil)

        res = req("GET", "/admin/api/metrics", headers: admin)
        assert_equal "200", res.code
        body = JSON.parse(res.body)
        assert_equal 1, body["profiles_total"]
        assert_equal 1, body["profiles_by_state"]["ready"]
        assert body["last_sync_age_seconds"]["min"].is_a?(Integer)
      end

      def test_patch_sets_sync_interval
        req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
        res = req("PATCH", "/admin/api/profiles/acme",
          body: { sync_interval_seconds: 3600 }, headers: admin)
        assert_equal "200", res.code
        body = JSON.parse(res.body)
        assert_equal 3600, body["profile"]["sync_interval_seconds"]
      end

      def test_patch_rejects_too_small_interval
        req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
        res = req("PATCH", "/admin/api/profiles/acme",
          body: { sync_interval_seconds: 60 }, headers: admin)
        assert_equal "400", res.code
      end

      def test_hidden_accounts_are_filtered_from_served_payload
        provision_profile_with_access_url("acme")
        req("PATCH", "/admin/api/profiles/acme",
          body: { hidden_accounts: ["b2"] }, headers: admin)

        envelope = {
          "accounts" => [
            { "id" => "a1", "currency" => "EUR", "balance" => "1.00",
              "balance-date" => Time.now.to_i, "transactions" => [] },
            { "id" => "b2", "currency" => "EUR", "balance" => "2.00",
              "balance-date" => Time.now.to_i, "transactions" => [] }
          ],
          "errors" => []
        }
        @feature.cache_store.write("acme", envelope)
        @feature.state_store.force_state("acme", "ready")

        url, user, password = current_access_url("acme")
        res = req("GET", url, headers: basic_auth(user, password))
        body = JSON.parse(res.body)
        assert_equal ["a1"], body["accounts"].map { |a| a["id"] }
      end

      def test_scheduler_tick_enqueues_due_profiles
        provision_profile_with_access_url("acme")
        # 300s minimum interval is too slow to test against a single tick, so
        # patch the profile on disk directly to a tiny interval. The protocol
        # layer's own coerce_interval floor protects the admin path.
        @feature.profile_store.update("acme") do |p|
          p["sync_interval_seconds"] = 1
          p
        end
        @feature.state_store.force_state("acme", "idle",
          "last_synced_at" => (Time.now - 60).utc.iso8601)

        @feature.scheduler_tick
        assert_includes @queue.enqueued.map(&:first), "acme"
      end

      def test_scheduler_tick_skips_running_and_needs_reauth
        provision_profile_with_access_url("acme")
        @feature.profile_store.update("acme") do |p|
          p["sync_interval_seconds"] = 1
          p
        end

        %w[running queued needs_reauth].each do |state|
          @queue.enqueued.clear
          @feature.state_store.force_state("acme", state,
            "last_synced_at" => (Time.now - 3600).utc.iso8601)
          @feature.scheduler_tick
          assert_empty @queue.enqueued, "must not enqueue from state=#{state}"
        end
      end

      def test_admin_login_rejects_wrong_password
        res = req("POST", "/admin/login", body: "password=wrong",
                  headers: { "Content-Type" => "application/x-www-form-urlencoded" })
        assert_equal "200", res.code   # re-renders login page
        assert_match(/Incorrect/, res.body)
      end

      # ── helpers ─────────────────────────────────────────────

      def provision_profile_with_access_url(key)
        req("POST", "/admin/api/profiles", body: { profile_key: key, workflow: @workflow_name }, headers: admin)
        res = req("POST", "/admin/api/profiles/#{key}/setup-token", headers: admin)
        claim_url = Base64.strict_decode64(JSON.parse(res.body)["setup_token"])
        @claim_response = req("POST", URI(claim_url).path)
      end

      def current_access_url(key)
        uri = URI(@claim_response.body.strip)
        user = URI.decode_www_form_component(uri.user)
        password = URI.decode_www_form_component(uri.password)
        [uri.path, user, password]
      end

      def basic_auth(user, password)
        { "Authorization" => "Basic #{Base64.strict_encode64("#{user}:#{password}")}" }
      end
    end
  end
end
