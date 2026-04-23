# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Freentonic
  module Exporters
    # POSTs the formatted payload to an HTTP endpoint.
    #
    # Options:
    #   url          — required. Full URL.
    #   token        — optional. Sent as "Authorization: Bearer <token>".
    #                  Falls back to FREENTONIC_HTTP_TOKEN env var so the
    #                  secret does not need to appear in your shell history
    #                  or process list.
    #   method       — "POST" or "PUT" (default "POST").
    #   content_type — overrides the formatter's declared Content-Type.
    #   format       — formatter name (default :canonical).
    #   headers      — hash of extra request headers.
    #
    # The selected formatter decides the wire shape and Content-Type. When
    # the formatter returns a Hash, `meta.freentonic_run_id` is merged in
    # (only Hash outputs have a place to carry it) and the result is
    # JSON.generate'd. When the formatter returns a String (CSV, NDJSON,
    # OFX XML), the bytes are sent verbatim and no meta merge happens.
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

        formatter = resolve_formatter
        formatted = formatter.call(payload)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        req = build_request(uri)
        req["Content-Type"] = @options[:content_type] || formatter.content_type
        req["Accept"] = "application/json"
        if (token = resolved_token)
          req["Authorization"] = "Bearer #{token}"
        end
        Array(@options[:headers]).each { |name, value| req[name] = value }
        req.body = encode_body(formatted)

        started_at = Time.now
        resp = begin
          http.request(req)
        rescue Errno::ECONNREFUSED
          raise ExportError, "http exporter: connection refused to #{uri.host}:#{uri.port} — is the server running?"
        rescue Net::OpenTimeout
          raise ExportError, "http exporter: connection to #{uri.host}:#{uri.port} timed out after #{OPEN_TIMEOUT}s"
        rescue SocketError => e
          raise ExportError, "http exporter: could not resolve #{uri.host} (#{e.message})"
        end

        result = handle_response(resp, url)
        # Emit a success line so the run log doesn't end at "Exporting via
        # http..." with nothing after — makes in-flight UIs look hung when
        # they're actually just done. Goes to $stdout to match the
        # "Exporting via ..." line that the Export stage writes; subprocess
        # stdout is redirected to the run's log under the invoke server.
        $stdout.puts "  → #{(@options[:method] || 'POST').to_s.upcase} #{url} → #{resp.code} in #{((Time.now - started_at) * 1000).to_i}ms"
        result
      end

      private

      # String formatter outputs go on the wire verbatim. Hash/Array
      # outputs get the run-id meta merge (when applicable) and are
      # JSON.generate'd. Strings have nowhere to carry the run id, so we
      # skip the merge for them.
      def encode_body(formatted)
        case formatted
        when String then formatted
        when Hash   then ::JSON.generate(with_run_id_meta(formatted))
        else             ::JSON.generate(formatted)
        end
      end

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

      # When the invoke server sets FREENTONIC_RUN_ID on the child process,
      # merge it into payload["meta"]["freentonic_run_id"] so the receiver
      # can correlate its ingest with the originating invoke. An explicit
      # meta.freentonic_run_id already set by the workflow takes precedence
      # (we never clobber). Payloads whose root isn't a Hash are returned
      # as-is — top-level arrays or primitives can't carry a meta key.
      def with_run_id_meta(payload)
        run_id = ENV["FREENTONIC_RUN_ID"]
        return payload if run_id.nil? || run_id.empty?
        return payload unless payload.is_a?(Hash)

        existing_meta = payload["meta"]
        if existing_meta.is_a?(Hash)
          return payload if existing_meta.key?("freentonic_run_id")
          payload.merge("meta" => existing_meta.merge("freentonic_run_id" => run_id))
        else
          payload.merge("meta" => { "freentonic_run_id" => run_id })
        end
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
