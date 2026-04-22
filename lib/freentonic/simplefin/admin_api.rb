# frozen_string_literal: true

require "base64"
require "json"
require "time"
require "yaml"

require_relative "crypto"
require_relative "http"
require_relative "paths"

module Freentonic
  module Simplefin
    # Admin REST API (Bearer `FREENTONIC_ADMIN_PASSWORD`). Every handler
    # returns JSON. Charset-validates every user-supplied id before
    # touching disk. Never returns plaintext credentials on reads.
    class AdminApi
      MAX_LOG_BYTES = 256 * 1024

      def initialize(feature:, workflows_dir:, runs_dir: nil)
        @feature       = feature
        @workflows_dir = workflows_dir
        @runs_dir      = runs_dir
      end

      def dispatch(client, method, path, request)
        pathname, _params = Http.split_query(path)
        return unauthorized(client) unless bearer_authenticated?(request)

        case
        when pathname == "/admin/api/status" && method == "GET"
          handle_status(client)
        when pathname == "/admin/api/metrics" && method == "GET"
          handle_metrics(client)
        when pathname == "/admin/api/workflows" && method == "GET"
          handle_workflows(client)
        when pathname == "/admin/api/profiles" && method == "GET"
          handle_list(client)
        when pathname == "/admin/api/profiles" && method == "POST"
          handle_create(client, request)
        when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)\z}))
          handle_profile(client, match[1], method, request)
        when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/credentials\z}))
          handle_credentials(client, match[1], method, request)
        when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/sync\z}))
          handle_sync(client, match[1], method, request)
        when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/setup-token\z}))
          handle_setup_token(client, match[1], method)
        when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/rotate-access-url\z}))
          handle_rotate(client, match[1], method)
        when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs\z}))
          return method_not_allowed(client) unless method == "GET"
          handle_runs(client, match[1])
        when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs/([^/]+)/log\z}))
          return method_not_allowed(client) unless method == "GET"
          handle_run_log(client, match[1], match[2])
        else
          Http.write_json(client, 404, { "error" => "not found" })
        end
      rescue StandardError => e
        @feature.log("admin api error: #{e.class}: #{e.message}")
        Http.write_json(client, 500, { "error" => "internal server error" })
      end

      private

      def bearer_authenticated?(request)
        token = Http.bearer_token(request.headers["authorization"])
        return false if token.nil?
        Crypto.secure_compare(token, @feature.admin_password)
      end

      # ── handlers ────────────────────────────────────────────

      def handle_status(client)
        profiles = @feature.profile_store.list
        entries = profiles.map { |p| profile_summary(p) }
        active_job = @feature.queue&.active_job
        active_payload = nil
        if active_job
          active_payload = {
            "profile_key" => active_job[:profile_key],
            "run_id"      => active_job[:run_id],
            "headed"      => active_job[:headed],
            "trigger"     => active_job[:trigger],
            "started_at"  => active_job[:started_at]
          }
          if active_job[:headed] && active_job[:vnc_password]
            active_payload["vnc_url"] = build_vnc_url(active_job[:vnc_password])
          end
        end
        Http.write_json(client, 200, {
          "profiles"   => entries,
          "active"     => @feature.queue&.active_key,
          "active_job" => active_payload,
          "pending"    => @feature.queue&.pending_keys || [],
          "server_ts"  => Time.now.utc.iso8601
        })
      end

      # Aggregate metrics across all profiles. Intended for a scrape by a
      # lightweight uptime monitor / dashboard. Not Prometheus-formatted —
      # plain JSON keeps the whole feature single-dependency.
      def handle_metrics(client)
        profiles = @feature.profile_store.list
        states   = Hash.new(0)
        last_ages = []
        error_count = 0
        now = Time.now

        profiles.each do |profile|
          state = @feature.state_store.read(profile["profile_key"])
          states[state["state"]] += 1
          error_count += 1 if state["last_error"]
          if state["last_synced_at"]
            last_ages << (now - Time.parse(state["last_synced_at"])).to_i rescue nil
          end
        end

        runs_today = 0
        cutoff = (now - 24 * 3600).utc.iso8601
        profiles.each do |profile|
          @feature.run_log.recent(profile["profile_key"], limit: 100).each do |r|
            runs_today += 1 if r["started_at"] && r["started_at"] >= cutoff
          end
        end

        last_ages.compact!
        Http.write_json(client, 200, {
          "profiles_total"      => profiles.size,
          "profiles_by_state"   => states,
          "profiles_with_error" => error_count,
          "runs_last_24h"       => runs_today,
          "queue" => {
            "active"  => @feature.queue&.active_key,
            "pending" => (@feature.queue&.pending_keys || []).size
          },
          "last_sync_age_seconds" => {
            "min"    => last_ages.min,
            "max"    => last_ages.max,
            "median" => median(last_ages)
          },
          "server_ts" => now.utc.iso8601
        })
      end

      def median(arr)
        return nil if arr.nil? || arr.empty?
        sorted = arr.sort
        mid = sorted.size / 2
        sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2)
      end

      def handle_workflows(client)
        list = list_workflows.map do |rel|
          secrets = declared_secrets(rel)
          { "workflow" => rel, "secrets" => secrets }
        end
        Http.write_json(client, 200, { "workflows" => list })
      end

      def handle_list(client)
        summaries = @feature.profile_store.list.map { |p| profile_summary(p) }
        Http.write_json(client, 200, { "profiles" => summaries })
      end

      def handle_create(client, request)
        body = parse_json(request) or return bad_request(client, "invalid JSON body")
        key      = body["profile_key"]
        workflow = body["workflow"]
        unless key.is_a?(String) && key =~ Paths::FILENAME_PATTERN
          return bad_request(client, "profile_key must match [A-Za-z0-9_.-]{1,128}")
        end
        unless workflow.is_a?(String) && !workflow.empty?
          return bad_request(client, "workflow is required")
        end
        unless File.file?(File.join(@workflows_dir, workflow))
          return bad_request(client, "workflow #{workflow.inspect} not found under workflows root")
        end

        profile = @feature.profile_store.create(
          key: key,
          workflow: workflow,
          display_name: body["display_name"],
          lookback_days: body["lookback_days"] || 30,
          max_lookback_days: body["max_lookback_days"] || 365,
          sync_interval_seconds: body["sync_interval_seconds"],
          hidden_accounts: body["hidden_accounts"] || []
        )
        Http.write_json(client, 200, { "profile" => profile_summary(profile) })
      rescue ArgumentError => e
        bad_request(client, e.message)
      end

      def handle_profile(client, key, method, request)
        return not_found(client) unless key =~ Paths::FILENAME_PATTERN
        case method
        when "GET"
          profile = @feature.profile_store.read(key) or return not_found(client)
          Http.write_json(client, 200, { "profile" => profile_summary(profile) })
        when "PATCH"
          body = parse_json(request) or return bad_request(client, "invalid JSON body")
          return not_found(client) unless @feature.profile_store.exists?(key)
          updated = @feature.profile_store.update(key) do |current|
            current["display_name"] = body["display_name"] if body.key?("display_name")
            if body.key?("workflow")
              wf = body["workflow"]
              unless wf.is_a?(String) && !wf.empty? && File.file?(File.join(@workflows_dir, wf))
                raise ArgumentError, "workflow #{wf.inspect} not found"
              end
              current["workflow"] = wf
            end
            if body.key?("lookback_days")
              current["lookback_days"] = coerce_positive(body["lookback_days"], "lookback_days")
            end
            if body.key?("max_lookback_days")
              current["max_lookback_days"] = coerce_positive(body["max_lookback_days"], "max_lookback_days")
            end
            if body.key?("sync_interval_seconds")
              raw = body["sync_interval_seconds"]
              current["sync_interval_seconds"] =
                (raw.nil? || raw == 0 || raw == "" || raw == "0") ? nil : coerce_interval(raw)
            end
            if body.key?("hidden_accounts")
              unless body["hidden_accounts"].is_a?(Array) && body["hidden_accounts"].all? { |v| v.is_a?(String) }
                raise ArgumentError, "hidden_accounts must be an array of strings"
              end
              current["hidden_accounts"] = body["hidden_accounts"].uniq
            end
            current
          end
          Http.write_json(client, 200, { "profile" => profile_summary(updated) })
        when "DELETE"
          return not_found(client) unless @feature.profile_store.exists?(key)
          @feature.profile_store.delete(key)
          @feature.cache_store.delete(key)
          Http.write_json(client, 200, { "deleted" => key })
        else
          method_not_allowed(client)
        end
      rescue ArgumentError => e
        bad_request(client, e.message)
      end

      def handle_credentials(client, key, method, request)
        return method_not_allowed(client) unless method == "POST"
        return not_found(client) unless @feature.profile_store.exists?(key)
        body = parse_json(request) or return bad_request(client, "invalid JSON body")
        secrets = body["secrets"]
        unless secrets.is_a?(Hash) && !secrets.empty?
          return bad_request(client, "secrets must be a non-empty object")
        end
        @feature.profile_store.write_credentials(key, secrets, master_key: @feature.master_key)
        Http.write_json(client, 200, { "ok" => true, "names" => secrets.keys.sort })
      rescue ArgumentError => e
        bad_request(client, e.message)
      end

      def handle_sync(client, key, method, request)
        return method_not_allowed(client) unless method == "POST"
        return not_found(client) unless @feature.profile_store.exists?(key)
        body = parse_json(request) || {}
        headed = body["headed"] == true

        # Headed syncs exist so the operator can complete a login through
        # noVNC. Mint a short, human-typeable VNC password per invocation
        # and return it to the admin so they can paste it into the noVNC
        # prompt. Headless syncs keep the random-unreachable default.
        vnc_password = headed ? random_vnc_password : nil
        result = @feature.queue&.enqueue(
          key, headed: headed, trigger: "admin", vnc_password: vnc_password
        ) || :disabled

        payload = { "enqueued" => result.to_s, "profile_key" => key, "headed" => headed }
        if headed && vnc_password
          payload["vnc_password"] = vnc_password
          payload["vnc_url"] = build_vnc_url(vnc_password)
        end
        Http.write_json(client, 200, payload)
      end

      # 8 alphanumeric chars. VNC's DES-based auth truncates at 8 chars, so
      # anything longer is wasted entropy; 8 chars of [A-Za-z0-9] is ~48 bits
      # of entropy, plenty for a throwaway per-invoke password.
      def random_vnc_password
        alphabet = (("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a)
        Array.new(8) { alphabet.sample(random: SecureRandom) }.join
      end

      def build_vnc_url(password)
        base = URI(@feature.public_url) rescue nil
        return nil unless base
        host = base.host
        scheme = base.scheme == "https" ? "https" : "http"
        # noVNC is exposed on 6080 separately from the admin UI's port;
        # we preserve the host and rewrite the port so a reverse-proxy
        # deployment still gets a useful hint. Operators fronting noVNC
        # with a different path/port should just ignore this field.
        "#{scheme}://#{host}:6080/vnc.html?host=#{host}&port=6080&password=#{URI.encode_www_form_component(password)}&autoconnect=true"
      end

      def handle_setup_token(client, key, method)
        return method_not_allowed(client) unless method == "POST"
        return not_found(client) unless @feature.profile_store.exists?(key)
        claim = @feature.claim_store.mint(key)
        url = "#{@feature.public_url}/simplefin/claim/#{claim["claim_id"]}"
        setup_token = Base64.strict_encode64(url)
        Http.write_json(client, 200, {
          "setup_token" => setup_token,
          "claim_url"   => url,
          "expires_at"  => claim["expires_at"]
        })
      end

      def handle_rotate(client, key, method)
        return method_not_allowed(client) unless method == "POST"
        return not_found(client) unless @feature.profile_store.exists?(key)
        @feature.profile_store.clear_access_url(key)
        Http.write_json(client, 200, {
          "ok" => true,
          "next_step" => "mint a new setup token and re-link in Actual"
        })
      end

      def handle_runs(client, key)
        return not_found(client) unless @feature.profile_store.exists?(key)
        Http.write_json(client, 200, { "runs" => @feature.run_log.recent(key, limit: 20) })
      end

      # Return the last N bytes of the underlying freentonic child's run log
      # (same file served by the main /runs/<run_id>/log route). We cap the
      # response at MAX_LOG_BYTES so large logs don't blow up the browser —
      # the UI uses this for a quick peek, not for live tailing.
      #
      # Path-traversal safe: run_id is charset-validated, and we verify the
      # realpath stays under the configured runs dir before reading.
      def handle_run_log(client, profile_key, run_id)
        return not_found(client) unless @feature.profile_store.exists?(profile_key)
        return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN
        return not_found(client) if @runs_dir.nil? || @runs_dir.empty?

        log_path = File.join(@runs_dir, run_id, "log")
        unless File.file?(log_path)
          return Http.write_json(client, 404, { "error" => "log not found" })
        end

        begin
          runs_real = File.realpath(@runs_dir)
          file_real = File.realpath(log_path)
        rescue Errno::ENOENT
          return Http.write_json(client, 404, { "error" => "log not found" })
        end
        unless file_real.start_with?(runs_real + File::SEPARATOR)
          return Http.write_json(client, 404, { "error" => "log path escapes runs dir" })
        end

        size = File.size(log_path)
        offset = [size - MAX_LOG_BYTES, 0].max
        body = File.open(log_path, "rb") do |f|
          f.seek(offset) if offset.positive?
          f.read(size - offset)
        end
        Http.write_json(client, 200, {
          "run_id"    => run_id,
          "truncated" => offset.positive?,
          "size"      => size,
          "log"       => body.to_s
        })
      end

      # ── helpers ─────────────────────────────────────────────

      def profile_summary(profile)
        state = @feature.state_store.read(profile["profile_key"])
        {
          "profile_key"           => profile["profile_key"],
          "display_name"          => profile["display_name"],
          "workflow"              => profile["workflow"],
          "lookback_days"         => profile["lookback_days"],
          "max_lookback_days"     => profile["max_lookback_days"],
          "sync_interval_seconds" => profile["sync_interval_seconds"],
          "hidden_accounts"       => profile["hidden_accounts"] || [],
          "created_at"            => profile["created_at"],
          "updated_at"            => profile["updated_at"],
          "credential_names"      => (profile["secrets_envelopes"] || {}).keys.sort,
          "access_url_configured" => !(profile.dig("access_url", "password_pw").nil?),
          "state"                 => state["state"],
          "last_error"            => state["last_error"],
          "last_run_id"           => state["last_run_id"],
          "last_synced_at"        => state["last_synced_at"]
        }
      end

      def list_workflows
        return [] unless @workflows_dir && Dir.exist?(@workflows_dir)
        Dir.glob(File.join(@workflows_dir, "**", "*.yml"))
          .map { |p| p.sub(@workflows_dir.chomp("/") + "/", "") }
          .sort
      end

      # Declared secrets for a workflow, used by the admin UI to render
      # credential-entry form fields. Goes through WorkflowSchema.load so
      # we get the same canonical list the runtime will ask for — plus
      # schema validation for free. YAML parsing is still safe_load with
      # no permitted classes (invariant 1).
      def declared_secrets(workflow_rel)
        full = File.join(@workflows_dir, workflow_rel)
        return [] unless File.file?(full)
        schema = Freentonic::WorkflowSchema.load(full)
        secrets = schema.secrets
        return [] unless secrets.is_a?(Hash)
        secrets.keys.map(&:to_s)
      rescue StandardError => e
        @feature.log("declared_secrets failed for #{workflow_rel}: #{e.class}: #{e.message}")
        []
      end

      def parse_json(request)
        JSON.parse(request.body)
      rescue ::JSON::ParserError, TypeError
        nil
      end

      def coerce_positive(value, name)
        int = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless int.positive?
        int
      end

      def coerce_interval(value)
        int = Integer(value)
        raise ArgumentError, "sync_interval_seconds must be >= 300 (5 min)" if int < 300
        int
      end

      def unauthorized(client)
        Http.write_json(client, 401, { "error" => "missing or invalid bearer token" })
      end

      def not_found(client)
        Http.write_json(client, 404, { "error" => "not found" })
      end

      def bad_request(client, msg)
        Http.write_json(client, 400, { "error" => msg })
      end

      def method_not_allowed(client)
        Http.write_json(client, 405, { "error" => "method not allowed" })
      end
    end
  end
end
