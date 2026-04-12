# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Freentonic
  module Exporters
    # POSTs the normalized payload as JSON to an HTTP endpoint.
    #
    # Options:
    #   url          — required. Full URL.
    #   token        — optional. Sent as "Authorization: Bearer <token>".
    #                  Falls back to FREENTONIC_HTTP_TOKEN env var so the
    #                  secret does not need to appear in your shell history
    #                  or process list.
    #   method       — "POST" or "PUT" (default "POST").
    #   content_type — default "application/json".
    #   headers      — hash of extra request headers.
    #
    # Non-2xx responses raise ExportError. Body is parsed as JSON on success;
    # the parsed result is returned for test/inspection but not written
    # anywhere by default.
    class Http < Base
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 60

      def write(payload)
        url = @options[:url] or raise UserError, "--export-url is required for the http exporter"
        uri = URI(url)

        # --export-url is the FULL endpoint URL. A bare host-only URL
        # almost always means the user expected the framework to append a
        # path automatically (it doesn't). Fail loud and actionable
        # instead of silently POSTing to /.
        if uri.path.nil? || uri.path.empty? || uri.path == "/"
          raise UserError,
                "http exporter: --export-url must include the full path, not just a host. " \
                "Got #{url.inspect}. Append the endpoint your receiver listens on, e.g. " \
                "#{url.chomp("/")}/your/endpoint/path"
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        req = build_request(uri)
        req["Content-Type"] = @options[:content_type] || "application/json"
        req["Accept"] = "application/json"
        if (token = resolved_token)
          req["Authorization"] = "Bearer #{token}"
        end
        Array(@options[:headers]).each { |name, value| req[name] = value }
        req.body = ::JSON.generate(payload)

        resp = begin
          http.request(req)
        rescue Errno::ECONNREFUSED
          raise ExportError, "http exporter: connection refused to #{uri.host}:#{uri.port} — is the server running?"
        rescue Net::OpenTimeout
          raise ExportError, "http exporter: connection to #{uri.host}:#{uri.port} timed out after #{OPEN_TIMEOUT}s"
        rescue SocketError => e
          raise ExportError, "http exporter: could not resolve #{uri.host} (#{e.message})"
        end
        handle_response(resp, url)
      end

      private

      def build_request(uri)
        case (@options[:method] || "POST").to_s.upcase
        when "POST" then Net::HTTP::Post.new(uri)
        when "PUT"  then Net::HTTP::Put.new(uri)
        else
          raise UserError, "http exporter: unsupported method #{@options[:method].inspect}"
        end
      end

      def resolved_token
        @options[:token] || ENV["FREENTONIC_HTTP_TOKEN"]
      end

      def handle_response(resp, url)
        status = resp.code.to_i
        case status
        when 200..299
          parse_body(resp.body)
        when 401
          raise ExportError, "http exporter: unauthorized (401) — check your --export-token"
        when 404
          raise ExportError,
                "http exporter: POST #{url} returned HTTP 404. Double-check that " \
                "--export-url points at the full endpoint path, not just the host."
        else
          raise ExportError, "http exporter: POST #{url} failed with HTTP #{status}: #{resp.body.to_s.slice(0, 200)}"
        end
      end

      def parse_body(body)
        return {} if body.to_s.empty?
        ::JSON.parse(body)
      rescue ::JSON::ParserError
        { "_raw" => body.to_s }
      end
    end

    register(:http, Http)
  end
end
