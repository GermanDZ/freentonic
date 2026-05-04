# frozen_string_literal: true

module Freentonic
    module SourceHelpers
      module_function

      def find_header(events, name)
        needle = name.downcase

        events.each do |event|
          next unless event["method"] == "Network.requestWillBeSent" ||
                      event["method"] == "Network.requestWillBeSentExtraInfo"

          headers = event.dig("params", "request", "headers") || event.dig("params", "headers") || {}
          headers.each do |key, value|
            return value.to_s.strip if key.to_s.downcase == needle
          end
        end

        nil
      end

      # Scan response events for a header on a request whose URL includes
      # both `host` and `path`. Used by the capture_response_header
      # workflow action — the post-elevation bearer ING mints during
      # PSD2 SCA arrives on a Network.responseReceived event for a
      # specific endpoint, and the workflow YAML needs to lift that value
      # into context[:credentials] so the api_client can pick it up.
      #
      # Walks Network.responseReceived (which carries both the URL and
      # the decoded response headers) and falls back to a requestId-
      # correlated Network.responseReceivedExtraInfo when the runtime
      # exposes the header only via the raw-headers path. Header lookup
      # is case-insensitive — Net::HTTP and CDP both normalize, but
      # banks have shipped both `Authorization` and `authorization` in
      # the wild.
      #
      # Most-recent match wins: a fresh-login handshake may produce
      # several responses on the same path during Connect, and the last
      # one is the one that carried the live token.
      def find_response_header(events, host:, path:, header:)
        needle    = header.downcase
        url_substr_host = host.to_s
        url_substr_path = path.to_s

        # Build a lookup of requestId → headers from ExtraInfo events for
        # the fallback case where a header (Set-Cookie, sometimes
        # Authorization on certain CDN paths) is only present there.
        extra_by_id = {}
        events.each do |event|
          next unless event["method"] == "Network.responseReceivedExtraInfo"
          rid = event.dig("params", "requestId")
          extra_by_id[rid] = event.dig("params", "headers") || {} if rid
        end

        result = nil
        events.each do |event|
          next unless event["method"] == "Network.responseReceived"
          url = event.dig("params", "response", "url").to_s
          next unless url.include?(url_substr_host) && url.include?(url_substr_path)

          headers = event.dig("params", "response", "headers") || {}
          rid = event.dig("params", "requestId")
          extra = (rid && extra_by_id[rid]) || {}

          # ExtraInfo wins when both have the header.
          merged = headers.merge(extra)
          merged.each do |key, value|
            result = value.to_s.strip if key.to_s.downcase == needle
          end
        end
        result
      end

      def cookie_header_for(session, host:, path:)
        cookies = Freentonic::ChromeCdp.get_all_cookies(session)
        applicable = Freentonic::ChromeCdp.applicable_cookies(cookies, host: host, path: path)
        filtered = Freentonic::ChromeCdp.dedupe_cookies(applicable)
        header = Freentonic::ChromeCdp.format_cookie_header(filtered)
        [filtered, header]
      end

      # Snapshot the listed headers from a recent outbound request whose
      # URL contains both host and path. Used by the
      # capture_outbound_request_headers workflow action to lift
      # JS-computed auth headers (Authorization, X-XSRF-TOKEN,
      # X-ING-ExtendedSessionContext, …) off the live session — values
      # the frontend constructs from in-memory state that the headless
      # extractor cannot reproduce.
      #
      # Walks Network.requestWillBeSent (which carries the URL +
      # request.headers) plus Network.requestWillBeSentExtraInfo
      # (which carries the post-CORS raw headers some Chrome versions
      # only put there). ExtraInfo wins on collision: when both forms
      # carry the header, prefer the raw-headers version.
      #
      # most_recent: true picks the latest matching request — a
      # fresh-login handshake may dispatch several before the live
      # values settle, and the latest is usually the one to capture.
      # most_recent: false picks the first.
      #
      # Returns a Hash of header_name → value, with ONLY the headers
      # that were actually present (missing names are absent, never nil-
      # filled, so the caller can distinguish "absent" from "set to
      # empty"). Returns {} when no request matched.
      def find_outbound_headers(events, host:, path:, headers:, most_recent: true)
        host_substr = host.to_s
        path_substr = path.to_s
        wanted = headers.map { |h| h.to_s.downcase }

        # Per-request_id raw-headers map from ExtraInfo events.
        extra_by_id = {}
        events.each do |event|
          next unless event["method"] == "Network.requestWillBeSentExtraInfo"
          rid = event.dig("params", "requestId")
          extra_by_id[rid] = event.dig("params", "headers") || {} if rid
        end

        matches = []
        events.each do |event|
          next unless event["method"] == "Network.requestWillBeSent"
          url = event.dig("params", "request", "url").to_s
          next unless url.include?(host_substr) && url.include?(path_substr)

          base_headers  = event.dig("params", "request", "headers") || {}
          rid           = event.dig("params", "requestId")
          extra_headers = (rid && extra_by_id[rid]) || {}

          merged = base_headers.merge(extra_headers)
          captured = {}
          merged.each do |key, value|
            next unless wanted.include?(key.to_s.downcase)
            captured[canonical_header_name(key, headers)] = value.to_s.strip
          end
          matches << captured unless captured.empty?
        end

        return {} if matches.empty?
        most_recent ? matches.last : matches.first
      end

      # Return the requested-name spelling for `key` so callers reading
      # ctx["ing_api_headers"]["Authorization"] don't have to
      # second-guess casing.
      def canonical_header_name(key, requested)
        downcase_key = key.to_s.downcase
        match = requested.find { |r| r.to_s.downcase == downcase_key }
        match ? match.to_s : key.to_s
      end

      def drain_session_events(session, iterations:, sleep_seconds:)
        iterations.times do
          sleep sleep_seconds
          session.send_command("Runtime.evaluate", { expression: "1" }) rescue nil
        end
      end
    end
  end
