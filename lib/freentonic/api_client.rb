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
      def auth_header(name, value = nil, from: nil)
        @auth_header_decls ||= []
        @auth_header_decls << { name: name, value: value, from: from }
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

      # Generate a public POST method (form-encoded body).
      # define_post :create_foo, "/foo",
      #   form: { ppp: "{ppp}", fechaDesde: "{fecha_desde|date}" }
      # response_extract_batch: same as define_get.
      def define_post(method_name, path_template, base: nil, form: {}, pagination: nil,
                      limit: 100, response_extract_batch: nil)
        _define_parameterized(method_name, :post, path_template, base: base,
                               request_template: form, pagination: pagination, limit: limit,
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

      # Declare credentials derived from other credentials via regex.
      # Generates a private memoized reader for each entry.
      #
      #   derived_credentials genoma_session_id: { from: :cookie,
      #     regex: 'genoma-session-id=([^;]+)', capture: 1 }
      def derived_credentials(derivations)
        derivations.each do |name, spec|
          name_sym  = name.to_sym
          ivar      = :"@#{name}"
          from_sym  = spec[:from].to_sym
          regex_str = spec[:regex].to_s
          cap_idx   = spec[:capture].to_i

          define_method(name_sym) do
            source = send(from_sym)
            return nil unless source
            return instance_variable_get(ivar) if instance_variable_defined?(ivar)
            m = source.match(Regexp.new(regex_str))
            instance_variable_set(ivar, m ? m[cap_idx] : nil)
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
                                 request_template: {}, pagination: nil, limit: 100,
                                 response_extract_batch: nil)
        rk = response_extract_batch
        define_method(method_name) do |**kwargs|
          resolved_url = base || self.class.get_base_url
          raise ArgumentError, "#{self.class}##{method_name}: no base URL configured" unless resolved_url
          path      = ep_interpolate_path(path_template, kwargs)
          full_path = "#{self.class.get_api_root}#{path}"

          case pagination&.to_s
          when "offset"
            paginate_by_offset(limit: limit) do |offset|
              resolved = ep_interpolate_hash(request_template, kwargs, offset: offset)
              data = http_method == :get ? get(resolved_url, full_path, params: resolved)
                                        : post(resolved_url, full_path, form: resolved)
              extract_batch(data)
            end
          else
            resolved = ep_interpolate_hash(request_template, kwargs)
            data = http_method == :get ? get(resolved_url, full_path, params: resolved)
                                       : post(resolved_url, full_path, form: resolved)
            rk ? ep_extract_batch(data, rk) : data
          end
        end
      end
    end

    # Default initializer: accepts an optional credentials hash and ignores it.
    # Subclasses that call the `credentials` macro override this.
    def initialize(credentials = {})
    end

    # ─── Instance API ─────────────────────────────────────────────────────

    protected

    # Issue a GET request. Returns parsed JSON.
    def get(base_url, path, params: {})
      request(:get, base_url, path, params: params)
    end

    # Issue a POST request with form-encoded body. Returns parsed JSON.
    def post(base_url, path, form: {})
      request(:post, base_url, path, form: form)
    end

    # Convenience: GET using the class-level base_url + api_root.
    def api_get(path, params: {})
      get(self.class.get_base_url, "#{self.class.get_api_root}#{path}", params: params)
    end

    # Convenience: POST using the class-level base_url + api_root.
    def api_post(path, form: {})
      post(self.class.get_base_url, "#{self.class.get_api_root}#{path}", form: form)
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

    def request(method, base_url, path, params: {}, form: {})
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
      auth_headers.each { |name, value| req[name] = value.to_s if value }

      if method == :post && form.any?
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

    def parse_json(body)
      return {} if body.to_s.empty?
      JSON.parse(body)
    rescue JSON::ParserError
      { "_raw" => body.to_s }
    end

    # Build auth headers from class-level auth_header declarations.
    # For dynamic entries (from:), calls send(method_name) on self.
    # Subclasses can still override this method entirely if needed.
    def auth_headers
      self.class.auth_header_decls.each_with_object({}) do |decl, h|
        value = decl[:from] ? send(decl[:from]) : decl[:value]
        h[decl[:name]] = value.to_s if value
      end
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
    # {name|date}   → format_date(kwargs[:name]).
    def ep_interpolate_val(val, kwargs, offset: nil)
      return val unless val.is_a?(String) && val.match?(/\A\{[^}]+\}\z/)
      inner = val[1..-2]
      return offset if inner == "offset"
      name, filter = inner.split("|", 2)
      raw = kwargs[name.to_sym]
      filter == "date" ? format_date(raw) : raw
    end
  end

  BankApiClient = ApiClient unless defined?(BankApiClient)
end
