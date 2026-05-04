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

      def drain_session_events(session, iterations:, sleep_seconds:)
        iterations.times do
          sleep sleep_seconds
          session.send_command("Runtime.evaluate", { expression: "1" }) rescue nil
        end
      end
    end
  end
