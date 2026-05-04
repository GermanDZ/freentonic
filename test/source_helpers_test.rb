# frozen_string_literal: true

require_relative "test_helper"

module Freentonic
  class SourceHelpersTest < Minitest::Test
    # Build a Network.responseReceived event with the given URL + headers.
    def response_event(url:, headers:, request_id: "req-1")
      {
        "method" => "Network.responseReceived",
        "params" => {
          "requestId" => request_id,
          "response"  => { "url" => url, "headers" => headers }
        }
      }
    end

    def extra_event(headers:, request_id: "req-1")
      {
        "method" => "Network.responseReceivedExtraInfo",
        "params" => { "requestId" => request_id, "headers" => headers }
      }
    end

    def test_find_response_header_returns_value_when_url_matches_host_and_path
      events = [
        response_event(url: "https://api.ing.ingdirect.es/saf/tpa/accesstoken/synchronize",
                       headers: { "Authorization" => "Bearer abc" })
      ]
      assert_equal "Bearer abc",
                   SourceHelpers.find_response_header(
                     events,
                     host: "api.ing.ingdirect.es",
                     path: "/saf/tpa/accesstoken/synchronize",
                     header: "Authorization"
                   )
    end

    def test_find_response_header_is_case_insensitive_on_header_name
      events = [response_event(url: "https://x.test/y", headers: { "authorization" => "Bearer x" })]
      assert_equal "Bearer x",
                   SourceHelpers.find_response_header(events, host: "x.test", path: "/y", header: "Authorization")
    end

    def test_find_response_header_returns_nil_when_url_does_not_match
      events = [response_event(url: "https://other.test/path", headers: { "Authorization" => "Bearer x" })]
      assert_nil SourceHelpers.find_response_header(events, host: "x.test", path: "/y", header: "Authorization")
    end

    def test_find_response_header_returns_nil_when_header_absent
      events = [response_event(url: "https://x.test/y", headers: { "X-Other" => "value" })]
      assert_nil SourceHelpers.find_response_header(events, host: "x.test", path: "/y", header: "Authorization")
    end

    def test_find_response_header_extra_info_wins_when_both_present
      # Reality: Chrome sometimes scrubs Authorization on
      # Network.responseReceived (the public-facing snapshot) while leaving
      # the raw value on responseReceivedExtraInfo. Prefer the extra-info
      # form when both are present, so we don't capture a redacted value.
      events = [
        response_event(url: "https://x.test/y", headers: { "Authorization" => "Bearer redacted" }),
        extra_event(headers: { "Authorization" => "Bearer real" })
      ]
      assert_equal "Bearer real",
                   SourceHelpers.find_response_header(events, host: "x.test", path: "/y", header: "Authorization")
    end

    def test_find_response_header_extra_info_alone_is_used
      events = [
        response_event(url: "https://x.test/y", headers: {}),
        extra_event(headers: { "Authorization" => "Bearer extra-only" })
      ]
      assert_equal "Bearer extra-only",
                   SourceHelpers.find_response_header(events, host: "x.test", path: "/y", header: "Authorization")
    end

    def test_find_response_header_most_recent_match_wins
      # On a fresh-login handshake the same endpoint may be hit twice; the
      # second response carries the live token. (Not the first.)
      events = [
        response_event(url: "https://x.test/y", headers: { "Authorization" => "Bearer stale" }, request_id: "r1"),
        response_event(url: "https://x.test/y", headers: { "Authorization" => "Bearer live" }, request_id: "r2")
      ]
      assert_equal "Bearer live",
                   SourceHelpers.find_response_header(events, host: "x.test", path: "/y", header: "Authorization")
    end

    def test_find_response_header_strips_whitespace
      events = [response_event(url: "https://x.test/y", headers: { "Authorization" => "  Bearer v  " })]
      assert_equal "Bearer v",
                   SourceHelpers.find_response_header(events, host: "x.test", path: "/y", header: "Authorization")
    end

    def test_find_response_header_ignores_non_response_events
      events = [
        {
          "method" => "Network.requestWillBeSent",
          "params" => { "request" => { "url" => "https://x.test/y", "headers" => { "Authorization" => "Bearer wrong" } } }
        }
      ]
      assert_nil SourceHelpers.find_response_header(events, host: "x.test", path: "/y", header: "Authorization")
    end
  end
end
