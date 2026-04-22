# frozen_string_literal: true

require "uri"

require_relative "crypto"
require_relative "http"
require_relative "paths"
require_relative "reshape"

module Freentonic
  module Simplefin
    # Public SimpleFIN protocol routes. These are reached by actual-server,
    # not by a human, so responses are narrow (text/plain for claim, JSON
    # for the accounts envelope) and errors are terse.
    #
    #   POST /simplefin/claim/:id       — one-shot token exchange
    #   GET  /simplefin/accounts/:key   — Basic-auth sync endpoint
    class Protocol
      # Minimum seconds between enqueue-from-GET-/accounts per profile.
      # Actual's sync button is one click per user action, but a runaway
      # client (or a test script) could hammer us and trigger a stream of
      # Chrome spawns. The window is conservative — one minute is way more
      # frequent than any sane bank-sync cadence.
      MIN_ENQUEUE_INTERVAL_SECONDS = 60

      def initialize(feature:, min_enqueue_interval: MIN_ENQUEUE_INTERVAL_SECONDS)
        @feature = feature
        @min_enqueue_interval = min_enqueue_interval
        @last_enqueue_mu = Mutex.new
        @last_enqueue    = {}
      end

      def dispatch(client, method, path, request)
        pathname, params = Http.split_query(path)

        # CORS preflight — echo the requested method + headers back when
        # the Origin is in our allow-list. Matches the SimpleFIN routes
        # only; the admin UI is same-origin and doesn't need CORS.
        if method == "OPTIONS" && pathname.start_with?("/simplefin/")
          return write_preflight(client, request)
        end

        headers = cors_headers_for(request)

        if (match = pathname.match(%r{\A/simplefin/claim/([^/]+)\z}))
          return Http.write_json(client, 405, { "error" => "method not allowed" }, headers: headers) unless method == "POST"
          return handle_claim(client, match[1], headers)
        end

        # New shape, matches real SimpleFIN: access URL ends at a base
        # (/simplefin/<key>), clients append /accounts to make the call.
        # Actual Budget's sync-server does exactly this in getAccounts().
        if (match = pathname.match(%r{\A/simplefin/([^/]+)/accounts\z}))
          return Http.write_json(client, 405, { "error" => "method not allowed" }, headers: headers) unless method == "GET"
          return handle_accounts(client, match[1], request, params, headers)
        end

        # Legacy flat shape: direct GET on /simplefin/accounts/<key>.
        # Kept so existing curl-based tests and copy-pasted access URLs
        # keep working. New tokens minted by this version use the new
        # shape above; this branch is strictly a back-compat alias.
        if (match = pathname.match(%r{\A/simplefin/accounts/([^/]+)\z}))
          return Http.write_json(client, 405, { "error" => "method not allowed" }, headers: headers) unless method == "GET"
          return handle_accounts(client, match[1], request, params, headers)
        end

        Http.write_json(client, 404, { "error" => "not found" }, headers: headers)
      end

      private

      # Exchange a setup-token claim for an access URL. Unauthenticated —
      # the claim ID itself is the secret (TTL + single-use). Responds
      # text/plain with the access URL on success.
      def handle_claim(client, claim_id, headers = {})
        outcome, profile_key = @feature.claim_store.consume!(claim_id)

        case outcome
        when :expired
          return Http.write_plain(client, 403, "claim expired", headers: headers)
        when :already_consumed
          return Http.write_plain(client, 403, "claim already used", headers: headers)
        when :unknown
          return Http.write_plain(client, 403, "claim not found", headers: headers)
        end

        profile = @feature.profile_store.read(profile_key)
        unless profile
          return Http.write_plain(client, 410, "profile for this claim was deleted", headers: headers)
        end

        username = "simplefin"
        password = Crypto.random_token(bytes: 24)
        @feature.profile_store.set_access_url(profile_key,
          username: username, password_plain: password)

        url = build_access_url(profile_key, username, password)
        @feature.log("claim #{claim_id} consumed → profile #{profile_key}")
        Http.write_plain(client, 200, url, headers: headers)
      end

      # The SimpleFIN /accounts endpoint. Basic auth with per-profile
      # credentials; drives the state machine:
      #
      #   ready        → consume cache, flip to idle, return payload
      #   idle         → enqueue, return empty+notice
      #   queued       → no-op (idempotent), return empty+notice
      #   running      → no-op (idempotent), return empty+notice
      #   needs_reauth → return error notice, do NOT enqueue
      #   error        → enqueue (single retry), return empty+notice
      def handle_accounts(client, profile_key, request, params, headers = {})
        return not_found(client, headers) unless profile_key =~ Paths::FILENAME_PATTERN

        auth_pair = Http.parse_basic_auth(request.headers["authorization"])
        return unauthorized(client, headers) unless auth_pair

        user, pw = auth_pair
        unless @feature.profile_store.verify_access(profile_key, user, pw)
          return unauthorized(client, headers)
        end

        # SimpleFIN clients (Actual's sync-server, the reference CLI) poll
        # /accounts repeatedly and expect the most-recent scraped data to
        # keep being returned until a newer scrape replaces it. Consuming
        # the cache on first read caused Actual to flag every account as
        # ACCOUNT_MISSING the second time it polled (transactions fetch,
        # periodic background refresh, UI reload, etc.).
        #
        # New semantics: cache is read-only here. New successful syncs
        # overwrite the file atomically. `state` now represents the
        # LAST SYNC'S outcome, independent of cache availability.
        envelope = @feature.cache_store.read(profile_key)
        state    = @feature.state_store.read(profile_key)

        if envelope && envelope["accounts"]
          filtered = Reshape.apply_query(envelope, params)
          profile  = @feature.profile_store.read(profile_key)
          hidden   = Array(profile && profile["hidden_accounts"])
          if hidden.any?
            filtered = filtered.merge(
              "accounts" => filtered["accounts"].reject { |a| hidden.include?(a["id"]) }
            )
          end
          # Opportunistically surface any sync-level issues in the errors
          # array so the client knows if the cached data is becoming stale.
          extra_errors = []
          case state["state"]
          when "error"
            extra_errors << "Background refresh failed: #{state["last_error"] || "unknown"}. Serving cached data."
            enqueue_if_possible(profile_key)
          when "needs_reauth"
            extra_errors << "Re-authentication required. Serving last-good cached data until the operator runs a headed sync."
          end
          if extra_errors.any?
            filtered = filtered.merge("errors" => Array(filtered["errors"]) + extra_errors)
          end
          return Http.write_json(client, 200, filtered, headers: headers)
        end

        # No cache yet — respond with the right scheduling hint for each
        # machine state. Don't enqueue from needs_reauth (would just loop
        # into the same failure).
        case state["state"]
        when "needs_reauth"
          Http.write_json(client, 200, {
            "accounts" => [],
            "errors"   => ["Re-authentication required. Ask the operator to run 'Re-authenticate via VNC' in the admin UI."]
          }, headers: headers)
        when "queued", "running"
          Http.write_json(client, 200, {
            "accounts" => [],
            "errors"   => ["Sync in progress. Data will be ready on the next call."]
          }, headers: headers)
        when "error"
          enqueue_if_possible(profile_key)
          Http.write_json(client, 200, {
            "accounts" => [],
            "errors"   => ["Last sync failed#{state["last_error"] ? ": #{state["last_error"]}" : ""}. Retry scheduled."]
          }, headers: headers)
        else
          enqueue_if_possible(profile_key)
          Http.write_json(client, 200, {
            "accounts" => [],
            "errors"   => ["No cached data yet. First sync scheduled."]
          }, headers: headers)
        end
      end

      def write_empty(client, message, enqueue: nil, headers: {})
        enqueue_if_possible(enqueue) if enqueue
        Http.write_json(client, 200, {
          "accounts" => [],
          "errors"   => [message]
        }, headers: headers)
      end

      def enqueue_if_possible(profile_key)
        return unless @feature.queue
        return unless allow_enqueue?(profile_key)
        @feature.queue.enqueue(profile_key, headed: false, trigger: "accounts")
      rescue StandardError => e
        @feature.log("enqueue failed for #{profile_key}: #{e.class}: #{e.message}")
      end

      # Per-profile rate limit on auto-enqueue triggered by GET /accounts.
      # Returns true (and records "now" as the last enqueue time) if the
      # last auto-enqueue was more than @min_enqueue_interval seconds ago;
      # false otherwise. Thread-safe against concurrent /accounts handlers.
      def allow_enqueue?(profile_key)
        now = Time.now.to_f
        @last_enqueue_mu.synchronize do
          last = @last_enqueue[profile_key]
          if last && (now - last) < @min_enqueue_interval
            return false
          end
          @last_enqueue[profile_key] = now
          true
        end
      end

      def unauthorized(client, extra_headers = {})
        Http.write(client, status: 401, body: "unauthorized",
          headers: extra_headers.merge(
            "WWW-Authenticate" => 'Basic realm="freentonic-simplefin"',
            "Content-Type"     => "text/plain"
          ))
      end

      def not_found(client, extra_headers = {})
        Http.write_json(client, 404, { "error" => "not found" }, headers: extra_headers)
      end

      # Build the CORS response headers for an incoming request. Returns
      # an empty hash (→ no CORS headers emitted) when the Origin is
      # missing or not in our allow-list, which falls back to same-origin-
      # only browser behaviour. Server-side clients (Actual's sync-server)
      # don't send Origin at all, so they bypass this path entirely.
      def cors_headers_for(request)
        origin = request.headers["origin"]
        allowed = @feature.cors_allowed_origins
        return {} if origin.nil? || origin.empty? || allowed.empty?
        return {} unless allowed.include?(origin)
        {
          "Access-Control-Allow-Origin"      => origin,
          "Access-Control-Allow-Credentials" => "true",
          "Vary"                             => "Origin"
        }
      end

      # Respond to a CORS preflight. Echoes the requested method + headers
      # back when the Origin is in our allow-list. Unknown origins get 403
      # so the browser drops the fetch with a useful error.
      def write_preflight(client, request)
        origin = request.headers["origin"]
        allowed = @feature.cors_allowed_origins
        if origin.nil? || origin.empty? || allowed.empty? || !allowed.include?(origin)
          return Http.write(client, status: 403, body: "CORS: origin not allowed",
            headers: { "Content-Type" => "text/plain" })
        end
        requested_method = request.headers["access-control-request-method"]
        requested_headers = request.headers["access-control-request-headers"] || "authorization, content-type"
        Http.write(client, status: 204, body: "",
          headers: {
            "Access-Control-Allow-Origin"      => origin,
            "Access-Control-Allow-Methods"     => requested_method || "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers"     => requested_headers,
            "Access-Control-Allow-Credentials" => "true",
            "Access-Control-Max-Age"           => "600",
            "Vary"                             => "Origin"
          })
      end

      def build_access_url(profile_key, username, password)
        base = URI(@feature.public_url)
        # The returned URL ends at the *base* — no trailing /accounts.
        # Clients (Actual's sync-server, the real SimpleFIN CLI) append
        # /accounts themselves. See handle_accounts' route pattern.
        "#{base.scheme}://#{URI.encode_www_form_component(username)}:" \
          "#{URI.encode_www_form_component(password)}@#{base.host}" \
          "#{base.port && base.port != default_port_for(base.scheme) ? ":#{base.port}" : ""}" \
          "/simplefin/#{profile_key}"
      end

      def default_port_for(scheme)
        scheme == "https" ? 443 : 80
      end
    end
  end
end
