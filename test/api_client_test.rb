require_relative "test_helper"

module Freentonic
  # Minimal concrete subclass that exposes protected/private methods for testing.
  class TestBankApiClient < Freentonic::ApiClient
    public :paginate_by_offset, :paginate_by_cursor, :handle_response, :parse_json, :auth_headers
    def pagination_sleep = nil  # skip inter-page delay in tests
  end

  # Client that exercises credentials / batch_keys / date_format macros.
  class MacroClient < Freentonic::ApiClient
    credentials :token, :secret, required: true
    batch_keys  "items", "results"
    date_format "%Y/%m/%d"
    def pagination_sleep = nil
    public :extract_batch, :format_date
  end

  # Client with static and dynamic auth_header declarations for DSL tests.
  class DeclaredHeaderClient < Freentonic::ApiClient
    base_url "https://api.example.com"
    api_root "/v1"
    auth_header "X-Static",  "static-val"
    auth_header "X-Dynamic", from: :dynamic_val

    define_get :fetch_things, "/things"
    define_get :fetch_other,  "/other", base: "https://other.example.com"

    def initialize(dynamic:)
      @dynamic = dynamic
    end

    def pagination_sleep = nil

    public :auth_headers

    private

    def dynamic_val = @dynamic
  end

  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](key) = headers&.fetch(key, nil)
  end

  class BankApiClientTest < Minitest::Test
    def client
      @client ||= TestBankApiClient.new
    end

    # ── paginate_by_offset ──────────────────────────────────────────

    def test_offset_pagination_collects_all_pages
      pages = [[1, 2, 3], [4, 5, 6], [7], []]
      calls = []
      result = client.paginate_by_offset(limit: 3) do |offset|
        calls << offset
        pages.shift || []
      end
      assert_equal [1, 2, 3, 4, 5, 6, 7], result
      assert_equal [0, 3, 6], calls
    end

    def test_offset_pagination_stops_on_partial_page
      pages = [[1, 2, 3], [4, 5]]
      result = client.paginate_by_offset(limit: 3) { pages.shift || [] }
      assert_equal [1, 2, 3, 4, 5], result
    end

    def test_offset_pagination_stops_on_empty_first_page
      result = client.paginate_by_offset { [] }
      assert_equal [], result
    end

    def test_offset_pagination_respects_max
      result = client.paginate_by_offset(limit: 3, max: 4) do |offset|
        offset < 9 ? [1, 2, 3] : []
      end
      assert result.size >= 4
      assert result.size <= 7  # stopped at or just after crossing max
    end

    # ── paginate_by_cursor ──────────────────────────────────────────

    def test_cursor_pagination_collects_all_pages
      pages = [
        [[10, 20], 100],
        [[30, 40], 200],
        [[50],     nil]
      ]
      cursors = []
      result = client.paginate_by_cursor do |cursor|
        cursors << cursor
        pages.shift || [[], nil]
      end
      assert_equal [10, 20, 30, 40, 50], result
      assert_equal [nil, 100, 200], cursors
    end

    def test_cursor_pagination_stops_on_nil_next_cursor
      result = client.paginate_by_cursor do
        [[1, 2], nil]
      end
      assert_equal [1, 2], result
    end

    def test_cursor_pagination_stops_on_cycle
      seen = []
      result = client.paginate_by_cursor(initial_cursor: 0) do |cursor|
        seen << cursor
        break [[], nil] if seen.size > 5  # safety guard
        cursor < 200 ? [[cursor], cursor + 100] : [[cursor], 100]
      end
      # 0 → batch [0], next 100
      # 100 → batch [100], next 200
      # 200 → batch [200], next 100 (cycle! seen includes 100)
      assert_equal [0, 100, 200], result
    end

    def test_cursor_pagination_initial_cursor_is_forwarded
      received = []
      client.paginate_by_cursor(initial_cursor: 42) do |cursor|
        received << cursor
        [[], nil]
      end
      assert_equal [42], received
    end

    # ── handle_response ─────────────────────────────────────────────

    def test_200_parses_json_body
      resp   = FakeResponse.new("200", '{"ok":true}', {})
      result = client.handle_response(resp)
      assert_equal({ "ok" => true }, result)
    end

    def test_401_raises_session_expired
      resp = FakeResponse.new("401", "Unauthorized", {})
      assert_raises(BankApiClient::SessionExpired) { client.handle_response(resp) }
    end

    def test_403_raises_session_expired
      resp = FakeResponse.new("403", "Forbidden", {})
      assert_raises(BankApiClient::SessionExpired) { client.handle_response(resp) }
    end

    def test_500_raises_api_error
      resp = FakeResponse.new("500", "Internal Server Error", {})
      err  = assert_raises(BankApiClient::ApiError) { client.handle_response(resp) }
      assert_equal 500, err.status
    end

    def test_api_error_message_is_utf8_when_body_is_ascii_8bit
      # Net::HTTP returns bodies as ASCII-8BIT. Banks send UTF-8 text in
      # error bodies ("momentáneamente"). The error message must be safely
      # interpolatable into UTF-8 strings without raising
      # Encoding::CompatibilityError.
      binary_body = %Q({"codigoError":"E0500","mensajeError":"Servicio no disponible momentáneamente"}).dup.force_encoding("ASCII-8BIT")
      resp = FakeResponse.new("500", binary_body, {})
      err  = assert_raises(BankApiClient::ApiError) { client.handle_response(resp) }
      assert_equal Encoding::UTF_8, err.message.encoding
      assert_includes err.message, "momentáneamente"
      # And interpolating into a UTF-8 format string must not raise.
      formatted = "    ✗ #{err.class}: #{err.message}"
      assert_includes formatted, "✗"
    end

    def test_api_error_message_scrubs_invalid_utf8_bytes
      invalid = "bad\xFFbytes".dup.force_encoding("ASCII-8BIT")
      resp = FakeResponse.new("500", invalid, {})
      err  = assert_raises(BankApiClient::ApiError) { client.handle_response(resp) }
      assert_equal Encoding::UTF_8, err.message.encoding
      assert err.message.valid_encoding?
    end

    # ── parse_json ──────────────────────────────────────────────────

    def test_parse_json_valid
      assert_equal({ "a" => 1 }, client.parse_json('{"a":1}'))
    end

    def test_parse_json_empty_body
      assert_equal({}, client.parse_json(""))
      assert_equal({}, client.parse_json(nil))
    end

    def test_parse_json_invalid_returns_raw
      result = client.parse_json("not-json")
      assert_equal "not-json", result["_raw"]
    end
  end

  class BankApiClientMacroTest < Minitest::Test
    def test_credentials_sets_instance_variables
      c = MacroClient.new(token: "tok", secret: "sec")
      assert_equal "tok", c.send(:token)
      assert_equal "sec", c.send(:secret)
    end

    def test_credentials_readers_are_private
      c = MacroClient.new(token: "tok", secret: "sec")
      assert_raises(NoMethodError) { c.token }
    end

    def test_credentials_required_raises_on_nil
      err = assert_raises(ArgumentError) { MacroClient.new(token: nil, secret: "sec") }
      assert_includes err.message, "token"
    end

    def test_batch_keys_returns_array_unchanged
      c = MacroClient.new(token: "t", secret: "s")
      assert_equal [1, 2], c.extract_batch([1, 2])
    end

    def test_batch_keys_returns_first_matching_key
      c = MacroClient.new(token: "t", secret: "s")
      assert_equal [3, 4], c.extract_batch("items" => [3, 4])
      assert_equal [5, 6], c.extract_batch("results" => [5, 6])
    end

    def test_batch_keys_returns_empty_on_no_match
      c = MacroClient.new(token: "t", secret: "s")
      assert_equal [], c.extract_batch("other" => [1])
    end

    def test_date_format_formats_date_object
      c = MacroClient.new(token: "t", secret: "s")
      assert_equal "2024/03/15", c.format_date(Date.new(2024, 3, 15))
    end

    def test_date_format_parses_string_first
      c = MacroClient.new(token: "t", secret: "s")
      assert_equal "2024/03/15", c.format_date("2024-03-15")
    end
  end

  class BankApiClientDslTest < Minitest::Test
    def client(dynamic: "dyn-val")
      DeclaredHeaderClient.new(dynamic: dynamic)
    end

    def test_static_auth_header_is_included
      assert_equal "static-val", client.auth_headers["X-Static"]
    end

    def test_dynamic_auth_header_calls_method
      assert_equal "dyn-val", client(dynamic: "dyn-val").auth_headers["X-Dynamic"]
    end

    def test_nil_dynamic_value_is_omitted
      assert_nil client(dynamic: nil).auth_headers["X-Dynamic"]
    end

    def test_base_url_and_api_root_stored_on_class
      assert_equal "https://api.example.com", DeclaredHeaderClient.get_base_url
      assert_equal "/v1",                     DeclaredHeaderClient.get_api_root
    end

    def test_define_get_uses_class_base_url_and_api_root
      # We can't make real HTTP calls, but we can verify the method exists
      # and that it would call get with the right URL by checking the class.
      assert_respond_to client, :fetch_things
      assert_respond_to client, :fetch_other
    end

    # ── update_auth_headers! ─────────────────────────────────────────────

    def test_update_auth_headers_overrides_dynamic_value
      c = client(dynamic: "dyn-val")
      assert_equal "dyn-val", c.auth_headers["X-Dynamic"]
      c.update_auth_headers!("X-Dynamic" => "rotated")
      assert_equal "rotated", c.auth_headers["X-Dynamic"]
    end

    def test_update_auth_headers_overrides_static_value
      c = client(dynamic: "x")
      c.update_auth_headers!("X-Static" => "rotated-static")
      assert_equal "rotated-static", c.auth_headers["X-Static"]
    end

    def test_update_auth_headers_can_add_a_brand_new_header
      # The PSD2 SCA case: an Authorization header that wasn't declared
      # in the original auth_header chain (e.g. session is cookie-based
      # until elevation, then bearer-based after) lands on every
      # subsequent request.
      c = client(dynamic: "x")
      refute c.auth_headers.key?("Authorization")
      c.update_auth_headers!("Authorization" => "Bearer abc")
      assert_equal "Bearer abc", c.auth_headers["Authorization"]
    end

    def test_update_auth_headers_nil_reverts_to_declared
      c = client(dynamic: "dyn-val")
      c.update_auth_headers!("X-Dynamic" => "rotated")
      c.update_auth_headers!("X-Dynamic" => nil)
      assert_equal "dyn-val", c.auth_headers["X-Dynamic"]
    end

    def test_update_auth_headers_returns_self_for_chaining
      c = client(dynamic: "x")
      assert_same c, c.update_auth_headers!("X" => "y")
    end
  end

  # ── Parameterized endpoints & derived_credentials ────────────────────

  class TemplateClient < Freentonic::ApiClient
    base_url "https://api.example.com"
    api_root "/v1"
    credentials :token
    batch_keys "items"
    date_format "%Y/%m/%d"

    define_get :fetch_resource, "/resources/{id}/data",
               params: { from: "{from_date|date}", limit: 10, offset: "{offset}" },
               pagination: :offset, limit: 10

    define_post :create_entry, "/entries",
                form: { ppp: "{ppp}", date: "{entry_date|date}", flag: "0" }

    derived_credentials genoma_session_id: {
      from: :token,
      regex: 'session-id=([^;]+)',
      capture: 1
    }

    def pagination_sleep = nil
    public :ep_interpolate_path, :ep_interpolate_hash, :ep_interpolate_val,
           :ep_extract_batch, :genoma_session_id
  end

  class BankApiClientTemplateTest < Minitest::Test
    def client(token: "session-id=abc123; other=x")
      TemplateClient.new(token: token)
    end

    # ── ep_interpolate_path ──────────────────────────────────────────

    def test_interpolate_path_replaces_token
      c = client
      assert_equal "/resources/42/data", c.ep_interpolate_path("/resources/{id}/data", id: "42")
    end

    def test_interpolate_path_multiple_tokens
      c = client
      assert_equal "/a/x/b/y", c.ep_interpolate_path("/a/{p}/b/{q}", p: "x", q: "y")
    end

    def test_interpolate_path_missing_token_raises
      c = client
      assert_raises(ArgumentError) { c.ep_interpolate_path("/x/{missing}", {}) }
    end

    # ── ep_interpolate_val ───────────────────────────────────────────

    def test_interpolate_val_plain_substitution
      c = client
      assert_equal "hello", c.ep_interpolate_val("{name}", { name: "hello" })
    end

    def test_interpolate_val_date_filter
      c = client
      assert_equal "2024/03/15", c.ep_interpolate_val("{d|date}", { d: Date.new(2024, 3, 15) })
    end

    def test_interpolate_val_offset_token
      c = client
      assert_equal 50, c.ep_interpolate_val("{offset}", {}, offset: 50)
    end

    def test_interpolate_val_literal_integer_passthrough
      c = client
      assert_equal 100, c.ep_interpolate_val(100, {})
    end

    def test_interpolate_val_literal_string_passthrough
      c = client
      assert_equal "static", c.ep_interpolate_val("static", {})
    end

    # ── ep_interpolate_hash ──────────────────────────────────────────

    def test_interpolate_hash_resolves_mixed
      c = client
      result = c.ep_interpolate_hash(
        { fromDate: "{from_date|date}", limit: 10, offset: "{offset}" },
        { from_date: Date.new(2024, 1, 1) },
        offset: 20
      )
      assert_equal "2024/01/01", result[:fromDate]
      assert_equal 10,           result[:limit]
      assert_equal 20,           result[:offset]
    end

    def test_interpolate_hash_omits_nil_values
      c = client
      result = c.ep_interpolate_hash({ key: "{missing_arg}" }, {})
      assert_empty result
    end

    # ── define_get with pagination ───────────────────────────────────

    def test_parameterized_define_get_method_exists
      assert_respond_to client, :fetch_resource
    end

    # ── define_post ──────────────────────────────────────────────────

    def test_define_post_method_exists
      assert_respond_to client, :create_entry
    end

    def test_define_post_form_and_json_are_mutually_exclusive
      err = assert_raises(ArgumentError) do
        Class.new(Freentonic::ApiClient) do
          base_url "https://api.example.com"
          define_post :bad_endpoint, "/x", form: { a: "{a}" }, json: { b: "{b}" }
        end
      end
      assert_match(/form: OR json:/, err.message)
    end

    # ── derived_credentials ──────────────────────────────────────────

    def test_derived_credential_extracts_via_regex
      c = TemplateClient.new(token: "session-id=abc123; other=x")
      assert_equal "abc123", c.genoma_session_id
    end

    def test_derived_credential_returns_nil_when_no_match
      c = TemplateClient.new(token: "no-match-here")
      assert_nil c.genoma_session_id
    end

    def test_derived_credential_returns_nil_when_source_nil
      c = TemplateClient.new(token: nil)
      assert_nil c.genoma_session_id
    end

    def test_derived_credential_is_memoized
      c = TemplateClient.new(token: "session-id=abc123; other=x")
      first  = c.genoma_session_id
      second = c.genoma_session_id
      assert_same first, second
    end

    # ── ep_extract_batch ─────────────────────────────────────────────

    def test_ep_extract_batch_returns_array_unchanged
      c = client
      assert_equal [1, 2], c.ep_extract_batch([1, 2], %w[items])
    end

    def test_ep_extract_batch_first_matching_key
      c = client
      assert_equal [3, 4], c.ep_extract_batch({ "products" => [3, 4] }, %w[products elements])
      assert_equal [5, 6], c.ep_extract_batch({ "elements" => [5, 6] }, %w[products elements])
    end

    def test_ep_extract_batch_returns_empty_on_no_match
      c = client
      assert_equal [], c.ep_extract_batch({ "other" => [1] }, %w[products elements])
    end

    def test_ep_extract_batch_returns_empty_on_non_hash
      c = client
      assert_equal [], c.ep_extract_batch("unexpected string", %w[products])
    end
  end

  # ── expected_response guard ──────────────────────────────────────────

  class GuardedClient < Freentonic::ApiClient
    base_url "https://api.example.com"
    expected_response content_type: "application/json"
    public :handle_response
  end

  class GuardedCodeClient < Freentonic::ApiClient
    base_url "https://api.example.com"
    expected_response code: 200
    public :handle_response
  end

  class BankApiClientExpectedResponseTest < Minitest::Test
    def test_200_with_matching_content_type_is_accepted
      c    = GuardedClient.new
      resp = FakeResponse.new("200", '{"ok":true}', { "content-type" => "application/json; charset=utf-8" })
      assert_equal({ "ok" => true }, c.handle_response(resp))
    end

    def test_200_with_html_content_type_raises_session_expired
      c    = GuardedClient.new
      resp = FakeResponse.new("200", "<html>login</html>", { "content-type" => "text/html" })
      err  = assert_raises(BankApiClient::SessionExpired) { c.handle_response(resp) }
      assert_includes err.message, "content-type"
    end

    def test_401_still_raises_session_expired_regardless_of_guard
      c    = GuardedClient.new
      resp = FakeResponse.new("401", "Unauthorized", {})
      assert_raises(BankApiClient::SessionExpired) { c.handle_response(resp) }
    end

    def test_expected_code_mismatch_raises_session_expired
      c    = GuardedCodeClient.new
      resp = FakeResponse.new("204", "", {})
      assert_raises(BankApiClient::SessionExpired) { c.handle_response(resp) }
    end

    def test_expected_code_match_is_accepted
      c    = GuardedCodeClient.new
      resp = FakeResponse.new("200", '{"ok":true}', {})
      assert_equal({ "ok" => true }, c.handle_response(resp))
    end
  end

  # ── raw_request ──────────────────────────────────────────────────────

  class RawRequestClient < Freentonic::ApiClient
    base_url "https://api.example.com"
    api_root "/v1"  # raw_request must NOT prepend this
    auth_header "X-Static",  "static-val"
    auth_header "X-Dynamic", from: :dyn

    def initialize(dyn:)
      @dyn = dyn
    end

    private

    def dyn = @dyn
  end

  RawFakeResp = Struct.new(:code, :body, :headers) do
    def [](key) = headers&.fetch(key.downcase, headers&.fetch(key, nil))
  end

  class RawRequestTest < Minitest::Test
    def fake_http(captured)
      h = Object.new
      h.define_singleton_method(:use_ssl=)      { |_| }
      h.define_singleton_method(:open_timeout=) { |_| }
      h.define_singleton_method(:read_timeout=) { |_| }
      h.define_singleton_method(:request) do |req|
        captured[:method]  = req.method
        captured[:path]    = req.path
        captured[:body]    = req.body
        captured[:headers] = req.each_header.to_h
        captured[:resp] || RawFakeResp.new("200", '{"ok":true}', { "content-type" => "application/json" })
      end
      h
    end

    def test_raw_request_get_returns_parsed_json
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        result = c.raw_request(method: :get, path: "/genoma_api/rest/sca/documentation")
        assert_equal({ "ok" => true }, result)
      end
      assert_equal "GET", captured[:method]
      assert_equal "/genoma_api/rest/sca/documentation", captured[:path]
      # api_root MUST NOT be prepended on raw_request
      refute_match %r{/v1/genoma_api}, captured[:path]
    end

    def test_raw_request_carries_existing_auth_headers
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "rotating-token")
        c.raw_request(method: :get, path: "/x")
      end
      assert_equal "static-val",      captured[:headers]["x-static"]
      assert_equal "rotating-token",  captured[:headers]["x-dynamic"]
    end

    def test_raw_request_caller_headers_override_auth_headers_on_collision
      # capture_response_header requirement: caller can supply
      # x-ing-reset-validations: 1 alongside the normal auth headers.
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        c.raw_request(method: :get, path: "/x",
                      headers: { "X-Static" => "overridden", "x-ing-reset-validations" => "1" })
      end
      assert_equal "overridden", captured[:headers]["x-static"]
      assert_equal "1",          captured[:headers]["x-ing-reset-validations"]
    end

    def test_raw_request_put_with_hash_body_sends_json
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        c.raw_request(method: :put, path: "/sca/documentation",
                      body: { "processId" => "abc-123" },
                      headers: { "x-ing-securityprocessid" => "abc-123" })
      end
      assert_equal "PUT", captured[:method]
      assert_equal({ "processId" => "abc-123" }, ::JSON.parse(captured[:body]))
      assert_equal "application/json", captured[:headers]["content-type"]
      assert_equal "abc-123", captured[:headers]["x-ing-securityprocessid"]
    end

    def test_raw_request_string_body_sent_verbatim_without_content_type_injection
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        c.raw_request(method: :post, path: "/x", body: "raw=bytes",
                      headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      end
      assert_equal "raw=bytes", captured[:body]
      assert_equal "application/x-www-form-urlencoded", captured[:headers]["content-type"]
    end

    def test_raw_request_base_override_lets_caller_target_a_different_host
      # The third hop of ING's SCA flow lives on
      # https://api.ing.ingdirect.es/, which is not the genoma_api base.
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        c.raw_request(method: :get,
                      path: "/saf/tpa/accesstoken/synchronize",
                      base: "https://api.ing.ingdirect.es")
      end
      # Net::HTTP::Get's req.path is the full URI's path; the host comes
      # from the URI we built. The fake_http above doesn't capture host
      # (it's read off the http instance, not the request), so we just
      # assert the path was preserved verbatim.
      assert_equal "/saf/tpa/accesstoken/synchronize", captured[:path]
    end

    def test_raw_request_query_params_serialized_into_url
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        c.raw_request(method: :get, path: "/getScaStatus",
                      params: { secProcessId: "p-1" })
      end
      assert_equal "/getScaStatus?secProcessId=p-1", captured[:path]
    end

    def test_raw_request_non_json_2xx_returns_raw_body
      captured = { resp: RawFakeResp.new("200", "<html>ok</html>", { "content-type" => "text/html" }) }
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        body = c.raw_request(method: :get, path: "/page")
        assert_equal "<html>ok</html>", body
      end
    end

    def test_raw_request_401_raises_session_expired
      captured = { resp: RawFakeResp.new("401", "Unauthorized", { "content-type" => "text/plain" }) }
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        assert_raises(Freentonic::ApiClient::SessionExpired) do
          c.raw_request(method: :get, path: "/x")
        end
      end
    end

    def test_raw_request_5xx_raises_api_error
      captured = { resp: RawFakeResp.new("503", "down", { "content-type" => "text/plain" }) }
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        err = assert_raises(Freentonic::ApiClient::ApiError) do
          c.raw_request(method: :get, path: "/x")
        end
        assert_equal 503, err.status
      end
    end

    def test_raw_request_unsupported_method_raises_argument_error
      c = RawRequestClient.new(dyn: "d")
      assert_raises(ArgumentError) do
        c.raw_request(method: :options, path: "/x")
      end
    end

    def test_raw_request_no_base_url_raises_argument_error
      anonymous = Class.new(Freentonic::ApiClient).new
      assert_raises(ArgumentError) do
        anonymous.raw_request(method: :get, path: "/x")
      end
    end

    def test_update_auth_headers_takes_effect_for_raw_request
      # PSD2 SCA round-trip: rotating the bearer must show up on the very
      # next raw_request as well as on declared endpoints.
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = RawRequestClient.new(dyn: "d")
        c.update_auth_headers!("Authorization" => "Bearer post-elevation")
        c.raw_request(method: :get, path: "/x")
      end
      assert_equal "Bearer post-elevation", captured[:headers]["authorization"]
    end
  end

  # ── Per-host auth_header scoping ─────────────────────────────────────

  class PerHostHeaderClient < Freentonic::ApiClient
    base_url "https://legacy.example.com"
    auth_header "Cookie",        from: :cookie
    auth_header "Authorization", from: :bearer, host: "api.example.com"
    auth_header "X-ESC",         from: :esc,    host: "api.example.com"

    def initialize(cookie:, bearer:, esc:)
      @cookie = cookie
      @bearer = bearer
      @esc    = esc
    end

    public :auth_headers_for, :auth_headers

    private

    attr_reader :cookie, :bearer, :esc
  end

  class PerHostAuthHeaderTest < Minitest::Test
    def client
      PerHostHeaderClient.new(cookie: "c=1", bearer: "Bearer abc", esc: "esc-val")
    end

    def test_legacy_host_omits_scoped_headers
      h = client.auth_headers_for("https://legacy.example.com/foo")
      assert_equal "c=1", h["Cookie"]
      refute h.key?("Authorization")
      refute h.key?("X-ESC")
    end

    def test_api_host_includes_scoped_headers
      h = client.auth_headers_for("https://api.example.com/v2/products")
      assert_equal "c=1",        h["Cookie"]
      assert_equal "Bearer abc", h["Authorization"]
      assert_equal "esc-val",    h["X-ESC"]
    end

    def test_unmatched_host_only_gets_unscoped_headers
      h = client.auth_headers_for("https://other.example.com/x")
      assert_equal "c=1", h["Cookie"]
      refute h.key?("Authorization")
    end

    def test_auth_headers_without_url_returns_unscoped_only
      h = client.auth_headers
      assert_equal "c=1", h["Cookie"]
      refute h.key?("Authorization")
    end

    def test_update_auth_headers_with_host_scopes_override
      c = client
      c.update_auth_headers!({ "Authorization" => "Bearer rotated" }, host: "api.example.com")

      api  = c.auth_headers_for("https://api.example.com/x")
      leg  = c.auth_headers_for("https://legacy.example.com/x")
      oth  = c.auth_headers_for("https://other.example.com/x")

      assert_equal "Bearer rotated", api["Authorization"]
      refute leg.key?("Authorization")
      refute oth.key?("Authorization")
    end

    def test_unscoped_override_applies_everywhere
      c = client
      c.update_auth_headers!("X-Trace" => "abc")
      assert_equal "abc", c.auth_headers_for("https://api.example.com/x")["X-Trace"]
      assert_equal "abc", c.auth_headers_for("https://legacy.example.com/x")["X-Trace"]
    end

    def test_host_scoped_override_wins_over_unscoped
      c = client
      c.update_auth_headers!("X-Trace" => "default")
      c.update_auth_headers!({ "X-Trace" => "api-only" }, host: "api.example.com")
      assert_equal "api-only", c.auth_headers_for("https://api.example.com/x")["X-Trace"]
      assert_equal "default",  c.auth_headers_for("https://legacy.example.com/x")["X-Trace"]
    end

    def test_host_scoped_nil_reverts_scoped_override
      c = client
      c.update_auth_headers!({ "Authorization" => "Bearer rotated" }, host: "api.example.com")
      c.update_auth_headers!({ "Authorization" => nil }, host: "api.example.com")
      assert_equal "Bearer abc", c.auth_headers_for("https://api.example.com/x")["Authorization"]
    end
  end

  # ── raw_request honors per-host scoping ─────────────────────────────

  class PerHostRawRequestClient < Freentonic::ApiClient
    base_url "https://legacy.example.com"
    auth_header "Cookie",        from: :cookie
    auth_header "Authorization", from: :bearer, host: "api.example.com"

    def initialize(cookie:, bearer:)
      @cookie = cookie
      @bearer = bearer
    end

    private

    attr_reader :cookie, :bearer
  end

  class PerHostRawRequestTest < Minitest::Test
    def fake_http(captured)
      h = Object.new
      h.define_singleton_method(:use_ssl=)      { |_| }
      h.define_singleton_method(:open_timeout=) { |_| }
      h.define_singleton_method(:read_timeout=) { |_| }
      h.define_singleton_method(:request) do |req|
        captured[:headers] = req.each_header.to_h
        captured[:resp] || RawFakeResp.new("200", '{"ok":true}', { "content-type" => "application/json" })
      end
      h
    end

    def test_raw_request_to_api_host_carries_bearer
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = PerHostRawRequestClient.new(cookie: "c=1", bearer: "Bearer abc")
        c.raw_request(method: :get, path: "/x", base: "https://api.example.com")
      end
      assert_equal "c=1",        captured[:headers]["cookie"]
      assert_equal "Bearer abc", captured[:headers]["authorization"]
    end

    def test_raw_request_to_legacy_host_omits_bearer
      captured = {}
      with_net_http_new(fake_http(captured)) do
        c = PerHostRawRequestClient.new(cookie: "c=1", bearer: "Bearer abc")
        c.raw_request(method: :get, path: "/x")  # default base = legacy host
      end
      assert_equal "c=1", captured[:headers]["cookie"]
      refute captured[:headers].key?("authorization")
    end
  end

  # ── derived_credentials key: (Hash pluck) form ───────────────────────

  class HashDerivedClient < Freentonic::ApiClient
    credentials :ing_api_headers

    derived_credentials ing_api_authorization: { from: :ing_api_headers, key: "Authorization" },
                        ing_api_esc:           { from: :ing_api_headers, key: "X-ING-ExtendedSessionContext" }

    public :ing_api_authorization, :ing_api_esc, :ing_api_headers
  end

  class HashDerivedCredentialsTest < Minitest::Test
    def test_key_plucks_value_from_hash_source
      c = HashDerivedClient.new(ing_api_headers: { "Authorization" => "Bearer abc",
                                                   "X-ING-ExtendedSessionContext" => "esc-val" })
      assert_equal "Bearer abc", c.ing_api_authorization
      assert_equal "esc-val",    c.ing_api_esc
    end

    def test_key_returns_nil_for_missing_key
      c = HashDerivedClient.new(ing_api_headers: { "Other" => "x" })
      assert_nil c.ing_api_authorization
    end

    def test_key_returns_nil_when_source_is_nil
      c = HashDerivedClient.new(ing_api_headers: nil)
      assert_nil c.ing_api_authorization
    end

    def test_key_returns_nil_when_source_is_not_a_hash
      c = HashDerivedClient.new(ing_api_headers: "not a hash")
      assert_nil c.ing_api_authorization
    end

    def test_key_branch_is_memoized
      c = HashDerivedClient.new(ing_api_headers: { "Authorization" => "Bearer first" })
      assert_equal "Bearer first", c.ing_api_authorization
      # Mutate the underlying credential — memoized value should be returned.
      c.ing_api_headers["Authorization"] = "Bearer second"
      assert_equal "Bearer first", c.ing_api_authorization
    end

    def test_key_reader_is_private
      c = HashDerivedClient.new(ing_api_headers: { "Authorization" => "Bearer x" })
      klass = Class.new(Freentonic::ApiClient) do
        credentials :ing_api_headers
        derived_credentials ing_api_authorization: { from: :ing_api_headers, key: "Authorization" }
      end
      instance = klass.new(ing_api_headers: c.ing_api_headers)
      assert_raises(NoMethodError) { instance.ing_api_authorization }
    end

    def test_macro_raises_when_both_regex_and_key_present
      err = assert_raises(ArgumentError) do
        Class.new(Freentonic::ApiClient) do
          derived_credentials foo: { from: :x, regex: "(.+)", key: "k" }
        end
      end
      assert_includes err.message, "both"
      assert_includes err.message, "regex"
      assert_includes err.message, "key"
    end

    def test_macro_raises_when_neither_regex_nor_key_present
      err = assert_raises(ArgumentError) do
        Class.new(Freentonic::ApiClient) do
          derived_credentials foo: { from: :x }
        end
      end
      assert_includes err.message, "must declare"
    end

    def test_regex_branch_still_works_unchanged
      # Same behavior as before — String source, capture group.
      klass = Class.new(Freentonic::ApiClient) do
        credentials :cookie
        derived_credentials sid: { from: :cookie, regex: 'sid=([^;]+)', capture: 1 }
        public :sid
      end
      c = klass.new(cookie: "sid=xyz789; other=1")
      assert_equal "xyz789", c.sid
    end

    def test_regex_branch_returns_nil_when_source_is_not_a_string
      # New explicit type guard — used to rely on Object#match raising.
      klass = Class.new(Freentonic::ApiClient) do
        credentials :payload
        derived_credentials sid: { from: :payload, regex: 'sid=([^;]+)', capture: 1 }
        public :sid
      end
      c = klass.new(payload: { "sid" => "xyz" })
      assert_nil c.sid
    end
  end

  # ── |iso interpolation filter ────────────────────────────────────────

  class IsoFilterClient < Freentonic::ApiClient
    date_format "%d/%m/%Y"
    public :ep_interpolate_val, :ep_format_iso
  end

  class IsoFilterTest < Minitest::Test
    def client = IsoFilterClient.new

    def test_iso_filter_formats_date
      assert_equal "2024-03-15",
                   client.ep_interpolate_val("{d|iso}", { d: Date.new(2024, 3, 15) })
    end

    def test_iso_filter_formats_datetime
      assert_equal "2024-03-15",
                   client.ep_interpolate_val("{d|iso}", { d: DateTime.new(2024, 3, 15, 10, 30) })
    end

    def test_iso_filter_parses_string
      assert_equal "2024-03-15",
                   client.ep_interpolate_val("{d|iso}", { d: "2024-03-15" })
    end

    def test_iso_filter_returns_nil_for_missing_kwarg
      assert_nil client.ep_interpolate_val("{d|iso}", {})
    end

    def test_iso_filter_raises_on_unparseable_string
      assert_raises(ArgumentError) do
        client.ep_format_iso("not a date")
      end
    end

    def test_iso_filter_coexists_with_date_filter
      # Same workflow, two filters — |date uses class date_format,
      # |iso always produces yyyy-mm-dd.
      d = Date.new(2024, 3, 15)
      assert_equal "15/03/2024", client.ep_interpolate_val("{d|date}", { d: d })
      assert_equal "2024-03-15", client.ep_interpolate_val("{d|iso}",  { d: d })
    end
  end

  # ── define_post with JSON body ───────────────────────────────────────
  #
  # The json: variant exists for modern APIs whose request bodies carry
  # array or nested-hash fields — form: stringifies through
  # URI.encode_www_form, which collapses Arrays to a lossy representation
  # the server can't round-trip. ING's /v2/products/transactions/search
  # is the motivating case (uuids: ["..."]).

  class JsonPostFixtureClient < Freentonic::ApiClient
    base_url "https://api.example.com"
    api_root "/v1"
    batch_keys "transactions"

    define_post :search_txs, "/search",
                json: {
                  uuids:       "{uuids}",
                  fromDate:    "{from_date|iso}",
                  limit:       100,
                  withComment: false
                }

    define_post :paged_search, "/paged-search",
                json: {
                  uuids:  "{uuids}",
                  offset: "{offset}",
                  limit:  2
                },
                pagination: :offset, limit: 2,
                response_extract_batch: ["transactions"]

    def pagination_sleep = nil
  end

  class JsonPostBodyTest < Minitest::Test
    def fake_http(captured, response_body: '{"transactions":[]}')
      h = Object.new
      h.define_singleton_method(:use_ssl=)      { |_| }
      h.define_singleton_method(:open_timeout=) { |_| }
      h.define_singleton_method(:read_timeout=) { |_| }
      h.define_singleton_method(:request) do |req|
        captured[:method]  = req.method
        captured[:path]    = req.path
        captured[:body]    = req.body
        captured[:headers] = req.each_header.to_h
        captured[:calls] ||= 0
        captured[:calls]  += 1
        bodies = captured[:response_bodies]
        body   = bodies ? bodies.shift || '{"transactions":[]}' : response_body
        RawFakeResp.new("200", body, { "content-type" => "application/json" })
      end
      h
    end

    def test_json_body_is_json_encoded_with_correct_content_type
      # No charset suffix on application/json. RFC 8259 doesn't define
      # one (JSON text is implicitly UTF-8) and at least one production
      # API (ING /v2/products/transactions/search) silently rejects
      # requests carrying ;charset=… by returning HTTP 200 with an
      # empty result body. Pin the canonical media type to prevent
      # accidental drift.
      captured = {}
      with_net_http_new(fake_http(captured)) do
        JsonPostFixtureClient.new.search_txs(uuids: ["a-uuid", "b-uuid"],
                                              from_date: Date.new(2026, 1, 1))
      end
      assert_equal "POST", captured[:method]
      assert_equal "application/json", captured[:headers]["content-type"]
    end

    def test_json_body_preserves_array_literal
      # The reason json: exists in the first place: arrays survive
      # round-trip. form-encoded would collapse this to a stringified
      # mess the bank's API would reject.
      captured = {}
      with_net_http_new(fake_http(captured)) do
        JsonPostFixtureClient.new.search_txs(uuids: ["a-uuid", "b-uuid"],
                                              from_date: Date.new(2026, 1, 1))
      end
      body = JSON.parse(captured[:body])
      assert_equal ["a-uuid", "b-uuid"], body["uuids"]
    end

    def test_json_body_applies_iso_date_filter
      captured = {}
      with_net_http_new(fake_http(captured)) do
        JsonPostFixtureClient.new.search_txs(uuids: ["x"],
                                              from_date: Date.new(2026, 5, 22))
      end
      assert_equal "2026-05-22", JSON.parse(captured[:body])["fromDate"]
    end

    def test_json_body_preserves_literal_integer_and_boolean
      # Form encoding stringifies everything, so 100 → "100" and
      # false → "false". The JSON path must preserve the YAML/Ruby
      # literal types so the server reads them as integer/boolean.
      captured = {}
      with_net_http_new(fake_http(captured)) do
        JsonPostFixtureClient.new.search_txs(uuids: ["x"], from_date: Date.new(2026, 1, 1))
      end
      body = JSON.parse(captured[:body])
      assert_kind_of Integer, body["limit"]
      assert_equal  100,      body["limit"]
      assert_equal  false,    body["withComment"]
    end

    def test_json_body_pagination_offset_resolves_inside_body
      captured = { response_bodies: [
        # Page 1: full batch of 2 → loop continues.
        '{"transactions":[{"id":1},{"id":2}]}',
        # Page 2: empty → loop terminates.
        '{"transactions":[]}'
      ] }
      with_net_http_new(fake_http(captured)) do
        JsonPostFixtureClient.new.paged_search(uuids: ["u"])
      end
      # Both pages went out as POSTs; the second carried offset=2 in
      # the JSON body (not as a query param).
      assert_equal 2, captured[:calls]
      last_body = JSON.parse(captured[:body])
      assert_equal 2, last_body["offset"]
      assert_equal ["u"], last_body["uuids"]
    end

    def test_form_post_path_unchanged_by_json_addition
      # Regression pin: existing form-encoded POST endpoints must keep
      # behaving identically — same content-type, same body encoding.
      captured = {}
      with_net_http_new(fake_http(captured)) do
        TemplateClient.new(token: "session-id=x").create_entry(
          ppp: "1234", entry_date: Date.new(2024, 3, 15)
        )
      end
      assert_equal "POST", captured[:method]
      assert_equal "application/x-www-form-urlencoded;charset=UTF-8",
                   captured[:headers]["content-type"]
      assert_equal "ppp=1234&date=2024%2F03%2F15&flag=0", captured[:body]
    end
  end

end
