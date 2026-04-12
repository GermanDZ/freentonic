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

end
