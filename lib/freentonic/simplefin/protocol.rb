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
      def initialize(feature:)
        @feature = feature
      end

      def dispatch(client, method, path, request)
        pathname, params = Http.split_query(path)

        if (match = pathname.match(%r{\A/simplefin/claim/([^/]+)\z}))
          return Http.write_json(client, 405, { "error" => "method not allowed" }) unless method == "POST"
          return handle_claim(client, match[1])
        end

        if (match = pathname.match(%r{\A/simplefin/accounts/([^/]+)\z}))
          return Http.write_json(client, 405, { "error" => "method not allowed" }) unless method == "GET"
          return handle_accounts(client, match[1], request, params)
        end

        Http.write_json(client, 404, { "error" => "not found" })
      end

      private

      # Exchange a setup-token claim for an access URL. Unauthenticated —
      # the claim ID itself is the secret (TTL + single-use). Responds
      # text/plain with the access URL on success.
      def handle_claim(client, claim_id)
        outcome, profile_key = @feature.claim_store.consume!(claim_id)

        case outcome
        when :expired
          return Http.write_plain(client, 403, "claim expired")
        when :already_consumed
          return Http.write_plain(client, 403, "claim already used")
        when :unknown
          return Http.write_plain(client, 403, "claim not found")
        end

        profile = @feature.profile_store.read(profile_key)
        unless profile
          return Http.write_plain(client, 410, "profile for this claim was deleted")
        end

        username = "simplefin"
        password = Crypto.random_token(bytes: 24)
        @feature.profile_store.set_access_url(profile_key,
          username: username, password_plain: password)

        url = build_access_url(profile_key, username, password)
        @feature.log("claim #{claim_id} consumed → profile #{profile_key}")
        Http.write_plain(client, 200, url)
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
      def handle_accounts(client, profile_key, request, params)
        return not_found(client) unless profile_key =~ Paths::FILENAME_PATTERN

        auth_pair = Http.parse_basic_auth(request.headers["authorization"])
        return unauthorized(client) unless auth_pair

        user, pw = auth_pair
        unless @feature.profile_store.verify_access(profile_key, user, pw)
          return unauthorized(client)
        end

        state = @feature.state_store.read(profile_key)
        case state["state"]
        when "ready"
          envelope = @feature.cache_store.consume(profile_key)
          @feature.state_store.force_state(profile_key, "idle",
            "last_error" => nil)
          if envelope.nil?
            return write_empty(client, "cache was unexpectedly empty; sync re-scheduled",
              enqueue: profile_key)
          end
          filtered = Reshape.apply_query(envelope, params)
          Http.write_json(client, 200, filtered)
        when "needs_reauth"
          Http.write_json(client, 200, {
            "accounts" => [],
            "errors"   => ["Connection Invalid: re-authentication required. " \
                           "Ask the operator to run 'Re-authenticate via VNC' in the admin UI."]
          })
        when "queued", "running"
          # Idempotent — do not double-enqueue.
          Http.write_json(client, 200, {
            "accounts" => [],
            "errors"   => ["Sync in progress. Data will be ready on the next call."]
          })
        when "error"
          # Auto-retry once per poll. Surface the last error message too.
          last = state["last_error"]
          enqueue_if_possible(profile_key)
          Http.write_json(client, 200, {
            "accounts" => [],
            "errors"   => ["Last sync failed#{last ? ": #{last}" : ""}. Retry scheduled."]
          })
        else
          enqueue_if_possible(profile_key)
          Http.write_json(client, 200, {
            "accounts" => [],
            "errors"   => ["Sync scheduled. Data will be ready on the next call."]
          })
        end
      end

      def write_empty(client, message, enqueue: nil)
        enqueue_if_possible(enqueue) if enqueue
        Http.write_json(client, 200, {
          "accounts" => [],
          "errors"   => [message]
        })
      end

      def enqueue_if_possible(profile_key)
        return unless @feature.queue
        @feature.queue.enqueue(profile_key, headed: false, trigger: "accounts")
      rescue StandardError => e
        @feature.log("enqueue failed for #{profile_key}: #{e.class}: #{e.message}")
      end

      def unauthorized(client)
        Http.write(client, status: 401, body: "unauthorized",
          headers: { "WWW-Authenticate" => 'Basic realm="freentonic-simplefin"',
                     "Content-Type"     => "text/plain" })
      end

      def not_found(client)
        Http.write_json(client, 404, { "error" => "not found" })
      end

      def build_access_url(profile_key, username, password)
        base = URI(@feature.public_url)
        "#{base.scheme}://#{URI.encode_www_form_component(username)}:" \
          "#{URI.encode_www_form_component(password)}@#{base.host}" \
          "#{base.port && base.port != default_port_for(base.scheme) ? ":#{base.port}" : ""}" \
          "/simplefin/accounts/#{profile_key}"
      end

      def default_port_for(scheme)
        scheme == "https" ? 443 : 80
      end
    end
  end
end
