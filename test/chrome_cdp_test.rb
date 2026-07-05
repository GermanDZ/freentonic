# frozen_string_literal: true

require_relative "test_helper"
require "socket"

module Freentonic
  # Unit coverage for ChromeCdp's pure helpers: profile-dir resolution,
  # the pgrep pattern used to target *our* Chrome (security-relevant — an
  # over-broad pattern could kill a neighbouring profile's browser), the
  # RFC 6265 cookie matching/dedupe helpers, and the RFC 6455 WebSocket
  # frame encode/decode pair. None of these touch a real Chrome, so they're
  # the cheapest untested risk to retire.
  class ChromeCdpTest < Minitest::Test
    # ─── profile-dir resolution ───

    def with_env(overrides)
      original = {}
      overrides.each do |k, v|
        original[k] = ENV[k]
        if v.nil? then ENV.delete(k) else ENV[k] = v end
      end
      yield
    ensure
      original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    def test_resolve_profile_dir_prefers_explicit_dir
      with_env("FREENTONIC_CHROME_PROFILE_DIR" => "/custom/prof",
               "FREENTONIC_CHROME_PROFILE_KEY" => "ignored") do
        assert_equal "/custom/prof", ChromeCdp.resolve_profile_dir_from_env
      end
    end

    def test_resolve_profile_dir_uses_key_under_default_root
      with_env("FREENTONIC_CHROME_PROFILE_DIR" => nil,
               "FREENTONIC_CHROME_PROFILE_KEY" => "ing-user1") do
        assert_equal File.join(ChromeCdp::DEFAULT_PROFILE_DIR, "ing-user1"),
                     ChromeCdp.resolve_profile_dir_from_env
      end
    end

    def test_resolve_profile_dir_falls_back_to_default
      with_env("FREENTONIC_CHROME_PROFILE_DIR" => nil,
               "FREENTONIC_CHROME_PROFILE_KEY" => nil) do
        assert_equal ChromeCdp::DEFAULT_PROFILE_DIR, ChromeCdp.resolve_profile_dir_from_env
      end
    end

    def test_empty_env_values_are_ignored
      with_env("FREENTONIC_CHROME_PROFILE_DIR" => "",
               "FREENTONIC_CHROME_PROFILE_KEY" => "") do
        assert_equal ChromeCdp::DEFAULT_PROFILE_DIR, ChromeCdp.resolve_profile_dir_from_env
      end
    end

    # ─── pgrep pattern escaping ───

    def test_pgrep_pattern_escapes_regex_metacharacters
      # A profile path with `.` and `+` must be escaped so `pgrep -f` treats
      # them literally instead of as regex wildcards.
      pattern = ChromeCdp.pgrep_pattern_for("/home/u/.cache/free+ntonic/chrome-1.0")
      assert_includes pattern, "user-data-dir="
      assert_includes pattern, '\\.cache'
      assert_includes pattern, 'free\\+ntonic'
      assert_includes pattern, 'chrome\\-1\\.0'
    end

    def test_pgrep_pattern_does_not_overmatch_a_sibling_profile
      # The escaped pattern for profile "chrome-a" must not match a launched
      # arg for "chromeXa" (which an unescaped `.` would).
      pattern = ChromeCdp.pgrep_pattern_for("/p/chrome-a")
      assert_match Regexp.new(pattern), "user-data-dir=/p/chrome-a"
      refute_match Regexp.new(pattern), "user-data-dir=/p/chromeXa"
    end

    # ─── RFC 6265 cookie matching ───

    def cookie(name: "sid", value: "v", domain: "example.com", path: "/")
      { "name" => name, "value" => value, "domain" => domain, "path" => path }
    end

    def test_cookie_domain_matches_exact_and_subdomain
      c = cookie(domain: "example.com")
      assert ChromeCdp.cookie_domain_matches?(c, "example.com")
      assert ChromeCdp.cookie_domain_matches?(c, "api.example.com")
      refute ChromeCdp.cookie_domain_matches?(c, "notexample.com")
      refute ChromeCdp.cookie_domain_matches?(c, "example.com.evil.com")
    end

    def test_cookie_domain_leading_dot_is_stripped
      assert ChromeCdp.cookie_domain_matches?(cookie(domain: ".example.com"), "example.com")
    end

    def test_cookie_domain_empty_never_matches
      refute ChromeCdp.cookie_domain_matches?(cookie(domain: ""), "example.com")
    end

    def test_cookie_path_matches
      assert ChromeCdp.cookie_path_matches?(cookie(path: "/"), "/anything")
      assert ChromeCdp.cookie_path_matches?(cookie(path: "/api"), "/api")
      assert ChromeCdp.cookie_path_matches?(cookie(path: "/api"), "/api/v1")
      # default path "/" when absent
      assert ChromeCdp.cookie_path_matches?({ "name" => "x" }, "/deep/path")
    end

    def test_applicable_cookies_filters_by_domain_and_path
      cookies = [
        cookie(name: "a", domain: "example.com", path: "/"),
        cookie(name: "b", domain: "other.com",   path: "/"),
        cookie(name: "c", domain: "example.com", path: "/admin")
      ]
      names = ChromeCdp.applicable_cookies(cookies, host: "example.com", path: "/api").map { |c| c["name"] }
      assert_equal %w[a], names
    end

    def test_dedupe_cookies_prefers_longer_path
      cookies = [
        cookie(name: "sid", value: "root",  path: "/"),
        cookie(name: "sid", value: "scoped", path: "/app")
      ]
      deduped = ChromeCdp.dedupe_cookies(cookies)
      assert_equal 1, deduped.size
      assert_equal "scoped", deduped.first["value"]
    end

    def test_dedupe_cookies_breaks_path_tie_by_longer_domain
      cookies = [
        cookie(name: "sid", value: "broad",  domain: ".example.com", path: "/"),
        cookie(name: "sid", value: "narrow", domain: "api.example.com", path: "/")
      ]
      deduped = ChromeCdp.dedupe_cookies(cookies)
      assert_equal 1, deduped.size
      assert_equal "narrow", deduped.first["value"]
    end

    def test_dedupe_cookies_keeps_distinct_names
      cookies = [cookie(name: "a"), cookie(name: "b")]
      assert_equal %w[a b], ChromeCdp.dedupe_cookies(cookies).map { |c| c["name"] }.sort
    end

    def test_format_cookie_header
      cookies = [cookie(name: "a", value: "1"), cookie(name: "b", value: "2")]
      assert_equal "a=1; b=2", ChromeCdp.format_cookie_header(cookies)
    end

    # ─── RFC 6455 WebSocket framing ───
    #
    # The encoder (ws_send_text) is tested against a byte-capturing sink —
    # no file descriptors, so the length/mask branches are pinned
    # deterministically. The decoder (ws_read_text) needs a real IO for its
    # IO.select, so it's fed frame bytes through one end of a socket pair.
    # Each end is closed exactly once by its own owner (the feeder thread
    # closes the write end; the test closes the read end) — no shared close,
    # no fd handed between threads, so nothing can double-close an fd that a
    # later test has since reused.

    # Minimal `write`-only sink capturing raw bytes.
    class ByteSink
      attr_reader :bytes
      def initialize
        @bytes = String.new(encoding: Encoding::BINARY)
      end

      def write(str)
        @bytes << str.b
        str.bytesize
      end
    end

    def encode(text)
      sink = ByteSink.new
      ChromeCdp.ws_send_text(sink, text)
      sink.bytes
    end

    # Decode a raw frame by streaming its bytes through a socket pair. The
    # writer thread owns and closes the write end; the caller owns the read
    # end. Works for payloads larger than the socket buffer because the
    # reader drains concurrently.
    def decode_frame(frame_bytes, timeout: 5)
      rd, wr = UNIXSocket.pair
      writer = Thread.new do
        wr.write(frame_bytes)
        wr.close
      end
      ChromeCdp.ws_read_text(rd, timeout: timeout)
    ensure
      writer&.join
      # Best-effort: the assertion has already been made. Under GC/scheduling
      # load the read-end fd can be reclaimed before this close, which would
      # otherwise surface as a spurious Errno::EBADF *after* a passing test.
      rd&.close rescue nil
    end

    def roundtrip(text)
      decode_frame(encode(text))
    end

    # ── encoder: frame structure per length branch ──

    def test_encode_short_payload_frame_structure
      bytes = encode("hi").bytes
      assert_equal 0x81, bytes[0]                  # FIN + text opcode
      assert_equal 0x80 | 2, bytes[1]              # mask bit + payload length 2
      assert_equal 1 + 1 + 4 + 2, bytes.size       # b0 + len byte + 4 mask + payload
    end

    def test_encode_uses_16bit_extended_length
      bytes = encode("x" * 300).bytes
      assert_equal 0x80 | 126, bytes[1]            # 126 ⇒ 16-bit length follows
      assert_equal 300, (bytes[2] << 8) | bytes[3]
    end

    def test_encode_uses_64bit_extended_length
      bytes = encode("y" * 70_000).bytes
      assert_equal 0x80 | 127, bytes[1]            # 127 ⇒ 64-bit length follows
      len = bytes[2, 8].inject(0) { |acc, b| (acc << 8) | b }
      assert_equal 70_000, len
    end

    def test_encode_masks_payload
      # Client frames MUST be masked (RFC 6455 §5.3): the mask bit is set and
      # the payload bytes are XORed, so the raw "AAAA" must not appear verbatim.
      bytes = encode("AAAA")
      assert_equal 0x80, bytes.bytes[1] & 0x80
      refute bytes.include?("AAAA")
    end

    # ── round-trip: encoder → decoder across each length branch ──

    def test_ws_roundtrip_short_payload
      assert_equal "hello CDP", roundtrip("hello CDP")
    end

    def test_ws_roundtrip_16bit_length_branch
      msg = "x" * 300
      assert_equal msg, roundtrip(msg)
    end

    def test_ws_roundtrip_64bit_length_branch
      # Just over the 16-bit boundary is enough to exercise the 127 / 64-bit
      # decode path while keeping the socket transfer small.
      msg = "y" * 65_600
      assert_equal msg, roundtrip(msg)
    end

    def test_ws_roundtrip_utf8_payload
      # ws_read_text returns a byte-exact ASCII-8BIT string (JSON.parse
      # re-interprets it as UTF-8 downstream), so compare bytes.
      msg = '{"método":"café ☕","n":"€1.234,56"}'
      assert_equal msg.b, roundtrip(msg)
    end

    # ── decoder: server (unmasked) frames + control opcodes ──

    def test_ws_read_decodes_unmasked_server_frame
      # Chrome (the server) sends UNMASKED frames — the production read path.
      # FIN + text opcode (0x81), len<126, no mask bit.
      payload = "pong".b
      frame = ([0x81, payload.bytesize] + payload.bytes).pack("C*")
      assert_equal "pong", decode_frame(frame)
    end

    def test_ws_read_raises_on_close_opcode
      frame = [0x88, 0x00].pack("C*") # FIN + close opcode, empty payload
      assert_raises(ChromeCdp::Error) { decode_frame(frame) }
    end

    def test_ws_read_times_out
      # No frame written; the read end stays open but silent.
      rd, wr = UNIXSocket.pair
      assert_raises(ChromeCdp::Error) { ChromeCdp.ws_read_text(rd, timeout: 0.2) }
    ensure
      wr&.close rescue nil
      rd&.close rescue nil
    end
  end
end
