# frozen_string_literal: true

require "date"
require "net/http"
require "uri"
require "json"

module Freentonic
  # Base class for bank HTTP API clients.
  # Handles Net::HTTP plumbing, error dispatch, JSON parsing, and pagination.
  #
  # Subclasses use class-level macros to declare their configuration:
  #
  #   class MyClient < BankApiClient
  #     base_url "https://api.example.com"
  #     api_root "/v2"                         # prepended to every path
  #
  #     auth_header "Cookie",  from: :cookie   # dynamic: calls send(:cookie)
  #     auth_header "Origin",  "https://example.com"  # static
  #
  #     define_get :fetch_accounts, "/accounts"
  #     define_get :fetch_products, "/products", base: OTHER_BASE  # override base per-endpoint
  #   end
  #
  class ApiClient
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    DEFAULT_UA   = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
                   "(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"

    class SessionExpired < StandardError; end
    class ApiError < StandardError
      attr_reader :status, :body
      def initialize(status, body)
        @status = status
        @body   = body
        # Net::HTTP hands back ASCII-8BIT bodies; banks send UTF-8 text
        # (accented characters in Spanish error messages). Force the
        # encoding and scrub invalid bytes so the message can be safely
        # interpolated into UTF-8 strings downstream.
        snippet = body.to_s.dup.force_encoding("UTF-8").scrub
        super("API error #{status}: #{snippet.slice(0, 200)}")
      end
    end

    # ─── Class-level DSL ──────────────────────────────────────────────────

    class << self
      # Default base URL for endpoints that don't specify their own.
      def base_url(url)
        @base_url = url
      end

      def get_base_url
        @base_url
      end

      # Path prefix prepended to every endpoint (e.g. "/services/rest/api").
      def api_root(root)
        @api_root = root
      end

      def get_api_root
        @api_root || ""
      end

      # Declare a request header.
      #   auth_header "Origin",  "https://example.com"     # static value
      #   auth_header "Cookie",  from: :cookie              # dynamic: send(:cookie) on the instance
      #
      # Pass host: "api.example.com" to scope the header to a single host —
      # it will only be attached to requests whose resolved URL has that
      # host. Useful when the client talks to two hosts with different auth
      # scopes (e.g. a legacy cookie host + a v2 bearer host) and one set
      # of headers must NOT leak to the other.
      def auth_header(name, value = nil, from: nil, host: nil)
        @auth_header_decls ||= []
        @auth_header_decls << { name: name, value: value, from: from, host: host }
      end

      def auth_header_decls
        @auth_header_decls || []
      end

      # Store raw api_client YAML config for yaml_value access.
      def yaml_config(config = nil)
        config ? @_yaml_config = config : @_yaml_config
      end

      # Generate a public GET method.
      # Simple form (no args/params/pagination): define_get :fetch_foo, "/foo"
      # Parameterized form: define_get :fetch_foo, "/products/{id}/foo",
      #   params: { fromDate: "{from_date|date}", limit: 100, offset: "{offset}" },
      #   pagination: :offset, limit: 100
      # In params values: {name} → kwargs[:name], {name|date} → format_date(kwargs[:name]),
      # {offset} → current pagination offset (injected by the loop).
      # response_extract_batch: array of JSON keys tried in order to unwrap the response body.
      def define_get(method_name, path_template, base: nil, params: {}, pagination: nil,
                     limit: 100, response_extract_batch: nil)
        if params.empty? && pagination.nil?
          rk = response_extract_batch
          define_method(method_name) do
            url = base || self.class.get_base_url
            raise ArgumentError, "#{self.class}##{method_name}: no base URL configured" unless url
            data = get(url, "#{self.class.get_api_root}#{path_template}")
            rk ? ep_extract_batch(data, rk) : data
          end
        else
          _define_parameterized(method_name, :get, path_template, base: base,
                                 request_template: params, pagination: pagination, limit: limit,
                                 response_extract_batch: response_extract_batch)
        end
      end

      # Generate a public POST method.
      #
      # Body shape — pass exactly one of:
      #
      #   form: form-encoded body. Values stringify via URI.encode_www_form,
      #   so nested structures (Arrays, Hashes) are lossy. Use for legacy
      #   APIs that expect application/x-www-form-urlencoded.
      #
      #     define_post :create_foo, "/foo",
      #       form: { ppp: "{ppp}", fechaDesde: "{fecha_desde|date}" }
      #
      #   json: JSON body (Content-Type: application/json). Values are
      #   serialized via JSON.generate, so Arrays / nested Hashes /
      #   booleans / integers round-trip unchanged. Use for modern JSON
      #   APIs whose request bodies carry array fields.
      #
      #     define_post :search_txs, "/v2/products/transactions/search",
      #       json: { uuids: "{uuids}", fromDate: "{from_date|iso}",
      #               offset: "{offset}", limit: 100, withComment: false }
      #
      # Templates inside form/json are interpolated identically — both
      # call ep_interpolate_hash, so {name}, {name|date}, {name|iso}, and
      # {offset} all work in either shape. Literal values (numbers,
      # booleans) pass through untouched, which only round-trips
      # correctly in the json case.
      #
      # response_extract_batch: same as define_get.
      def define_post(method_name, path_template, base: nil, form: nil, json: nil,
                      pagination: nil, limit: 100, response_extract_batch: nil)
        if form && json
          raise ArgumentError,
                "define_post(#{method_name.inspect}): pass form: OR json:, not both"
        end
        body_format = json ? :json : :form
        template    = json || form || {}
        _define_parameterized(method_name, :post, path_template, base: base,
                               request_template: template, body_format: body_format,
                               pagination: pagination, limit: limit,
                               response_extract_batch: response_extract_batch)
      end

      # Guard the response content-type and/or status code for successful (2xx) responses.
      # If a 2xx response does not match expected_code or includes unexpected_content_type,
      # raises SessionExpired (server is likely returning an auth redirect page).
      #
      #   expected_response code: 200, content_type: "application/json"
      def expected_response(code: nil, content_type: nil)
        code_i  = code&.to_i
        ct_str  = content_type&.to_s
        define_method(:handle_response) do |resp|
          status = resp.code.to_i
          if (200..299).cover?(status)
            if code_i && status != code_i
              raise SessionExpired, "session expired — expected HTTP #{code_i}, got #{status}"
            end
            if ct_str && !resp["content-type"].to_s.include?(ct_str)
              raise SessionExpired,
                    "session expired — unexpected content-type: #{resp["content-type"].inspect}"
            end
          end
          super(resp)
        end
        private :handle_response
      end

      # Declare credentials derived from other credentials.
      # Generates a private memoized reader for each entry.
      #
      # Two extraction modes — exactly one per entry:
      #
      #   regex: + capture: — match a String source with the pattern and
      #   return the capture group (defaults to 1). Source not a String
      #   yields nil.
      #
      #     derived_credentials genoma_session_id: { from: :cookie,
      #       regex: 'genoma-session-id=([^;]+)', capture: 1 }
      #
      #   key: — pluck a single key out of a Hash source. Single-level
      #   lookup only (use ext: for nested paths). Source not a Hash, or
      #   key missing, yields nil.
      #
      #     derived_credentials ing_api_authorization: { from: :ing_api_headers,
      #       key: "Authorization" }
      def derived_credentials(derivations)
        derivations.each do |name, spec|
          name_sym = name.to_sym
          ivar     = :"@#{name}"
          from_sym = spec[:from].to_sym
          has_regex = spec.key?(:regex) && !spec[:regex].nil?
          has_key   = spec.key?(:key)   && !spec[:key].nil?

          if has_regex && has_key
            raise ArgumentError, "derived_credentials[#{name.inspect}]: " \
                                 "cannot declare both regex: and key:"
          elsif !has_regex && !has_key
            raise ArgumentError, "derived_credentials[#{name.inspect}]: " \
                                 "must declare regex: or key:"
          end

          if has_regex
            regex_str = spec[:regex].to_s
            cap_idx   = (spec[:capture] || 1).to_i
            define_method(name_sym) do
              source = send(from_sym)
              return nil unless source.is_a?(String)
              return instance_variable_get(ivar) if instance_variable_defined?(ivar)
              m = source.match(Regexp.new(regex_str))
              instance_variable_set(ivar, m ? m[cap_idx] : nil)
            end
          else
            key = spec[:key].to_s
            define_method(name_sym) do
              source = send(from_sym)
              return nil unless source.is_a?(Hash)
              return instance_variable_get(ivar) if instance_variable_defined?(ivar)
              instance_variable_set(ivar, source[key])
            end
          end
          private name_sym
        end
      end

      # Declare the credential keys the client reads from the credentials hash.
      # Generates initialize(credentials), private attr_readers, and optional
      # presence validation.
      #
      #   credentials :cookie
      #   credentials :cookie, :tokencsrf, required: true
      def credentials(*names, required: false)
        names.each { |name| attr_reader name; private name }
        define_method(:initialize) do |creds|
          names.each { |name| instance_variable_set(:"@#{name}", creds[name]) }
          if required
            missing = names.select { |name| send(name).nil? }
            raise ArgumentError, "missing credentials: #{missing.join(", ")}" unless missing.empty?
          end
        end
      end

      # Declare the JSON response keys to try when extracting a batch array.
      # Generates extract_batch(data) that returns the first matching key's value.
      #
      #   batch_keys "transactions", "movements", "elements", "resultList"
      def batch_keys(*keys)
        keys_s = keys.map(&:to_s)
        define_method(:extract_batch) do |data|
          return data if data.is_a?(Array)
          return [] unless data.is_a?(Hash)
          keys_s.each { |k| (v = data[k]) && (return v) }
          []
        end
      end

      # Declare the strftime format used by format_date.
      # Generates format_date(date) that accepts a Date or ISO String.
      #
      #   date_format "%d/%m/%Y"
      def date_format(fmt)
        define_method(:format_date) do |date|
          date = Date.parse(date) if date.is_a?(String)
          date.strftime(fmt)
        end
      end

      private

      def _define_parameterized(method_name, http_method, path_template, base:,
                                 request_template: {}, body_format: :form,
                                 pagination: nil, limit: 100,
                                 response_extract_batch: nil)
        rk = response_extract_batch
        define_method(method_name) do |**kwargs|
          resolved_url = base || self.class.get_base_url
          raise ArgumentError, "#{self.class}##{method_name}: no base URL configured" unless resolved_url
          path      = ep_interpolate_path(path_template, kwargs)
          full_path = "#{self.class.get_api_root}#{path}"

          dispatch = lambda do |resolved|
            case http_method
            when :get
              get(resolved_url, full_path, params: resolved)
            when :post
              if body_format == :json
                json_post(resolved_url, full_path, json: resolved)
              else
                post(resolved_url, full_path, form: resolved)
              end
            end
          end

          case pagination&.to_s
          when "offset"
            paginate_by_offset(limit: limit) do |offset|
              resolved = ep_interpolate_hash(request_template, kwargs, offset: offset)
              extract_batch(dispatch.call(resolved))
            end
          else
            resolved = ep_interpolate_hash(request_template, kwargs)
            data = dispatch.call(resolved)
            rk ? ep_extract_batch(data, rk) : data
          end
        end
      end
    end

    # Default initializer: accepts an optional credentials hash and ignores it.
    # Subclasses that call the `credentials` macro override this.
    def initialize(credentials = {})
    end

    # ─── Instance API (public) ────────────────────────────────────────────

    # Issue an ad-hoc HTTP request outside the workflow's declared endpoints
    # block. Honors the client's existing auth_headers (including any
    # in-flight overrides from update_auth_headers!), base_url, and
    # timeouts.
    #
    # Use this for endpoints the workflow YAML can't declare statically —
    # the canonical case is PSD2 SCA elevation, where the bank's
    # documentation endpoint, the status poll, and the access-token
    # refresh all live outside the normal pagination loop and only fire
    # mid-extraction. Keeping them out of the YAML keeps the YAML readable
    # and lets the extractor decide when to dispatch them based on
    # provider-specific signals (e.g. an acceptanceMethods[].code value).
    #
    # @param method [Symbol] :get / :post / :put / :delete / :patch
    # @param path [String] absolute path under the resolved base (api_root
    #   is NOT prepended — raw_request is the explicit form)
    # @param headers [Hash] caller-supplied headers; override auth_headers
    #   on a name collision
    # @param body [Hash, String, nil] Hash → JSON-encoded with
    #   Content-Type: application/json (unless caller set one); String →
    #   sent as-is, caller owns Content-Type; nil → no body
    # @param base [String, nil] override the class-level base_url for this
    #   single call (e.g. ING's accesstoken host vs the genoma_api host)
    # @param params [Hash, nil] query-string parameters
    # @return [Object] parsed JSON for application/json 2xx responses;
    #   raw body string otherwise
    # @raise [SessionExpired] on 401/403
    # @raise [ApiError] on any other non-2xx
    def raw_request(method:, path:, headers: {}, body: nil, base: nil, params: nil)
      base_url = base || self.class.get_base_url
      raise ArgumentError, "raw_request: no base URL configured (pass base: or set base_url at the class level)" unless base_url

      uri = URI("#{base_url}#{path}")
      uri.query = URI.encode_www_form(params) if params && !params.empty?

      req_class = case method.to_sym
                  when :get    then Net::HTTP::Get
                  when :post   then Net::HTTP::Post
                  when :put    then Net::HTTP::Put
                  when :delete then Net::HTTP::Delete
                  when :patch  then Net::HTTP::Patch
                  else raise ArgumentError, "raw_request: unsupported method #{method.inspect}"
                  end
      req = req_class.new(uri)

      req["User-Agent"]      = DEFAULT_UA
      req["Accept"]          = "application/json"
      req["Accept-Language"] = "es-ES"
      auth_headers_for(base_url).each { |name, value| req[name] = value.to_s if value }
      headers.each                    { |name, value| req[name] = value.to_s if value }

      if body
        if body.is_a?(String)
          req.body = body
        else
          req["Content-Type"] = "application/json" unless req["Content-Type"]
          req.body = JSON.generate(body)
        end
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      handle_raw_response(http.request(req))
    end

    # Replace one or more auth headers post-construction. Subsequent
    # requests — declared endpoints AND raw_request — see the new values.
    #
    # The original auth_header declarations (static or `from:` dynamic)
    # remain in place; overrides take precedence on a name collision.
    # Pass a value of nil to delete the override and revert to the
    # declared value (or, if there isn't a declared one, drop the header
    # entirely). Returns self for chaining.
    #
    # Use case: after a PSD2 SCA elevation handshake, the bank mints a new
    # bearer token. update_auth_headers!("Authorization" => "Bearer #{new}")
    # rotates it onto the client without rebuilding the client (which
    # would lose pagination state, retry counters, etc.).
    #
    # Pass host: "api.example.com" to scope the override to a single host.
    # The override then only applies to requests whose URL has that host;
    # other hosts continue to see the declared (or previously-overridden,
    # unscoped) value. Without host:, the override applies to all hosts
    # (back-compat behavior).
    def update_auth_headers!(headers_hash = nil, host: nil, **other_headers)
      # Accept both explicit-hash calls — update_auth_headers!({"X" => "y"}, host: "api") —
      # and implicit-hash calls — update_auth_headers!("X" => "y"). In the implicit
      # form Ruby 3 routes the trailing hash into **other_headers since host: is the
      # only explicit kwarg, so we fold it back into headers_hash here.
      headers_hash = other_headers if headers_hash.nil?
      @auth_header_overrides ||= {}
      headers_hash.each do |k, v|
        key = [k.to_s, host]
        if v.nil?
          @auth_header_overrides.delete(key)
        else
          @auth_header_overrides[key] = v.to_s
        end
      end
      self
    end

    # ─── Instance API (protected) ─────────────────────────────────────────

    protected

    # Issue a GET request. Returns parsed JSON.
    def get(base_url, path, params: {})
      request(:get, base_url, path, params: params)
    end

    # Issue a POST request with form-encoded body. Returns parsed JSON.
    def post(base_url, path, form: {})
      request(:post, base_url, path, form: form)
    end

    # Issue a POST request with a JSON body. Returns parsed JSON. The
    # `json:` argument is serialized via JSON.generate, so Arrays /
    # nested Hashes / booleans survive round-trip unchanged — which the
    # form-encoded path can't promise (URI.encode_www_form stringifies
    # everything).
    def json_post(base_url, path, json: {})
      request(:post, base_url, path, json: json)
    end

    # Convenience: GET using the class-level base_url + api_root.
    def api_get(path, params: {})
      get(self.class.get_base_url, "#{self.class.get_api_root}#{path}", params: params)
    end

    # Convenience: POST using the class-level base_url + api_root.
    def api_post(path, form: {})
      post(self.class.get_base_url, "#{self.class.get_api_root}#{path}", form: form)
    end

    # Convenience: POST a JSON body using the class-level base_url + api_root.
    def api_json_post(path, json: {})
      json_post(self.class.get_base_url, "#{self.class.get_api_root}#{path}", json: json)
    end

    # Read a value from the api_client: YAML section.
    # Available in ext module methods: yaml_value("base_url")
    def yaml_value(key)
      self.class.yaml_config[key.to_s]
    end

    # Offset-based pagination.
    # Block receives the current offset and must return an Array (the page).
    # Stops when the page is empty or smaller than limit.
    def paginate_by_offset(limit: 100, max: 10_000, &block)
      all    = []
      offset = 0
      loop do
        batch = block.call(offset)
        break if batch.empty?
        all.concat(batch)
        offset += limit
        break if batch.size < limit
        break if all.size >= max
        pagination_sleep
      end
      all
    end

    # Cursor-based pagination.
    # Block receives the current cursor and must return [batch_array, next_cursor].
    # Stops when batch is empty, next_cursor is nil, or a cursor repeats.
    def paginate_by_cursor(initial_cursor: nil, max: 10_000, &block)
      all    = []
      cursor = initial_cursor
      seen   = []
      loop do
        batch, next_cursor = block.call(cursor)
        break if batch.empty?
        all.concat(batch)
        break if all.size >= max
        break if next_cursor.nil?
        break if seen.include?(next_cursor)
        seen << next_cursor
        cursor = next_cursor
        pagination_sleep
      end
      all
    end

    # Overridable in tests to skip the inter-page delay.
    def pagination_sleep
      sleep(0.3)
    end

    private

    def request(method, base_url, path, params: {}, form: {}, json: nil)
      uri = URI("#{base_url}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = case method
            when :get  then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            end

      req["User-Agent"]      = DEFAULT_UA
      req["Accept"]          = "application/json"
      req["Accept-Language"] = "es-ES"
      auth_headers_for(base_url).each { |name, value| req[name] = value.to_s if value }

      if method == :post && !json.nil?
        # No charset suffix. application/json is implicitly UTF-8 per
        # RFC 8259, but more importantly ING's API edge silently
        # rejects requests whose Content-Type carries `;charset=…`,
        # returning HTTP 200 with an empty `transactions: []` body
        # rather than an error status. raw_request has always used
        # the bare media type; keep json_post consistent.
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(json)
      elsif method == :post && form.any?
        req["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"
        req.body = URI.encode_www_form(form)
      end

      handle_response(http.request(req))
    end

    def handle_response(resp)
      case resp.code.to_i
      when 200..299 then parse_json(resp.body)
      when 401, 403 then raise SessionExpired, "session expired (HTTP #{resp.code})"
      else               raise ApiError.new(resp.code.to_i, resp.body)
      end
    end

    # Variant of handle_response used by raw_request: returns parsed JSON
    # only when the response advertises application/json, else hands back
    # the raw body string. Declared endpoints all parse JSON, but
    # raw_request is a general-purpose escape hatch and may be pointed at
    # text/html, application/xml, or anything else.
    def handle_raw_response(resp)
      case resp.code.to_i
      when 200..299
        if resp["content-type"].to_s.include?("application/json")
          parse_json(resp.body)
        else
          resp.body.to_s
        end
      when 401, 403 then raise SessionExpired, "session expired (HTTP #{resp.code})"
      else               raise ApiError.new(resp.code.to_i, resp.body)
      end
    end

    def parse_json(body)
      return {} if body.to_s.empty?
      JSON.parse(body)
    rescue JSON::ParserError
      { "_raw" => body.to_s }
    end

    # Build auth headers for a request to a specific URL. Resolves
    # class-level auth_header declarations and update_auth_headers!
    # overrides against the URL's host, so headers scoped to one host
    # (e.g. an api.* Bearer) don't leak to another (e.g. the legacy
    # cookie host).
    #
    # Resolution order — later passes override earlier ones on a name
    # collision; nil values produce no header:
    #
    #   1. Unscoped declarations (no host:).
    #   2. Declarations whose host: matches URI(url).host.
    #   3. Unscoped overrides from update_auth_headers!.
    #   4. Host-scoped overrides from update_auth_headers!(host: ...).
    #
    # A nil url resolves to host=nil, so only unscoped declarations and
    # overrides apply — that's the back-compat path for `auth_headers`.
    def auth_headers_for(url)
      target_host = url ? URI(url.to_s).host : nil
      result = {}

      self.class.auth_header_decls.each do |decl|
        next if decl[:host]
        value = decl[:from] ? send(decl[:from]) : decl[:value]
        result[decl[:name]] = value.to_s if value
      end

      self.class.auth_header_decls.each do |decl|
        next unless decl[:host] && decl[:host] == target_host
        value = decl[:from] ? send(decl[:from]) : decl[:value]
        result[decl[:name]] = value.to_s if value
      end

      overrides = @auth_header_overrides
      if overrides && !overrides.empty?
        overrides.each { |(name, h), v| result[name] = v if h.nil? }
        overrides.each { |(name, h), v| result[name] = v if h && h == target_host }
      end

      result
    end

    # Back-compat alias. Returns unscoped declarations + unscoped
    # overrides. Use auth_headers_for(url) when host scoping matters.
    def auth_headers
      auth_headers_for(nil)
    end

    # ─── Endpoint template helpers ────────────────────────────────────

    # Unwrap a response body using an endpoint-level key list.
    # Complements the class-level extract_batch (batch_keys macro).
    # Array → returned as-is; Hash → first matching key's value; else [].
    def ep_extract_batch(data, keys)
      return data if data.is_a?(Array)
      return [] unless data.is_a?(Hash)
      keys.each { |k| (v = data[k.to_s]) && (return v) }
      []
    end

    # Replace {name} tokens in a path template with values from kwargs.
    def ep_interpolate_path(template, kwargs)
      template.gsub(/\{(\w+)\}/) do
        kwargs.fetch($1.to_sym) { raise ArgumentError, "missing :#{$1} for path #{template}" }
      end
    end

    # Resolve a hash whose values may contain {name} / {name|date} / {offset} tokens.
    def ep_interpolate_hash(template_hash, kwargs, offset: nil)
      template_hash.each_with_object({}) do |(k, v), h|
        resolved = ep_interpolate_val(v, kwargs, offset: offset)
        h[k.to_sym] = resolved unless resolved.nil?
      end
    end

    # Resolve a single template value.
    # Literal (non-string or no {…}) → returned as-is.
    # {offset}      → the pagination offset integer.
    # {name}        → kwargs[:name].
    # {name|date}   → format_date(kwargs[:name]) (workflow's date_format).
    # {name|iso}    → kwargs[:name] formatted as yyyy-mm-dd, regardless
    #                 of date_format. Accepts Date, DateTime, or String;
    #                 raises ArgumentError on unparseable strings.
    def ep_interpolate_val(val, kwargs, offset: nil)
      return val unless val.is_a?(String) && val.match?(/\A\{[^}]+\}\z/)
      inner = val[1..-2]
      return offset if inner == "offset"
      name, filter = inner.split("|", 2)
      raw = kwargs[name.to_sym]
      case filter
      when "date" then format_date(raw)
      when "iso"  then ep_format_iso(raw)
      else raw
      end
    end

    def ep_format_iso(raw)
      return nil if raw.nil?
      d = raw.is_a?(Date) ? raw : Date.parse(raw.to_s)
      d.strftime("%Y-%m-%d")
    end
  end

  BankApiClient = ApiClient unless defined?(BankApiClient)
end
