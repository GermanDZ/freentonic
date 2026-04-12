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
