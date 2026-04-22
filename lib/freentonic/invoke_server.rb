# frozen_string_literal: true

require "socket"
require "json"
require "time"
require "fileutils"

require_relative "invoke_request"

module Freentonic
  # Long-running HTTP server that accepts /invoke requests and hands each one
  # to an InvokeRunner under a single global mutex.
  #
  # Minimal HTTP/1.1 server built on stdlib Socket — avoids the runtime
  # dependency on webrick (which became a bundled gem in Ruby 3.0 and is not
  # preinstalled in the slim Ruby images we build on).
  #
  # Auth: if @invoke_token is set, clients must send
  #   Authorization: Bearer <token>
  # Missing/incorrect tokens return 401.
  class InvokeServer
    DEFAULT_ADDR = "127.0.0.1"
    DEFAULT_PORT = 7878

    MAX_BODY_BYTES  = 1 * 1024 * 1024 # 1 MiB
    MAX_HEADER_BYTES = 16 * 1024
    READ_TIMEOUT    = 30

    CANCEL_GRACE_SECONDS = 10

    STATUS_REASONS = {
      200 => "OK",
      202 => "Accepted",
      206 => "Partial Content",
      400 => "Bad Request",
      401 => "Unauthorized",
      404 => "Not Found",
      405 => "Method Not Allowed",
      409 => "Conflict",
      413 => "Payload Too Large",
      416 => "Range Not Satisfiable",
      422 => "Unprocessable Entity",
      500 => "Internal Server Error",
      503 => "Service Unavailable",
      504 => "Gateway Timeout"
    }.freeze

    RUN_ID_PATTERN     = /\A[A-Za-z0-9_\-:.]{1,64}\z/.freeze
    LOG_CHUNK_BYTES    = 64 * 1024

    def initialize(
      runner:,
      invoke_token: nil,
      listen_addr: DEFAULT_ADDR,
      listen_port: DEFAULT_PORT,
      logger: $stdout
    )
      @runner          = runner
      @invoke_token    = (invoke_token && !invoke_token.empty?) ? invoke_token : nil
      @listen_addr     = listen_addr
      @listen_port     = listen_port
      @logger          = logger

      @invoke_mutex    = Mutex.new
      @in_flight_mutex = Mutex.new
      @in_flight       = {}
      @shutting_down   = false
      @server_socket   = nil
    end

    def start
      @server_socket = TCPServer.new(@listen_addr, @listen_port)
      log "listening on http://#{@listen_addr}:#{@listen_port}" \
          "#{@invoke_token ? " (auth: bearer token)" : " (auth: OPEN — no token set)"}"

      loop do
        break if @shutting_down
        begin
          client = @server_socket.accept
        rescue IOError, Errno::EBADF, Errno::EINVAL, Errno::ENOTSOCK
          break
        end
        Thread.new(client) { |c| handle_connection(c) }
      end
    ensure
      @server_socket&.close rescue nil
    end

    # Safe to call from a signal handler.
    def shutdown
      @shutting_down = true
      # Closing the server socket wakes accept() with an error.
      @server_socket&.close rescue nil
    end

    def shutting_down?
      @shutting_down
    end

    private

    # ─── HTTP wire protocol ───

    def handle_connection(client)
      client.sync = true
      begin
        request = read_request(client)
      rescue RequestTooLarge
        write_response(client, 413, { "error" => "payload too large" })
        return
      rescue RequestMalformed => e
        write_response(client, 400, { "error" => "malformed request: #{e.message}" })
        return
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET, Errno::ETIMEDOUT
        return
      end
      return unless request

      # The log route streams bytes directly to the socket (logs can be large
      # and we support Range requests), so it can't use the [status, hash]
      # dispatcher like the JSON endpoints. Handle it here before dispatch.
      path = request.path.split("?", 2).first
      if (match = path.match(%r{\A/runs/([^/]+)/log\z}))
        if request.method == "GET"
          handle_log(client, request, match[1])
        else
          write_response(client, 405, { "error" => "method not allowed" })
        end
        return
      end

      status, body = dispatch(request)
      write_response(client, status, body)
    rescue StandardError => e
      log_exception("connection", e)
      begin
        write_response(client, 500, { "error" => "internal server error" })
      rescue StandardError
        nil
      end
    ensure
      client.close rescue nil
    end

    class RequestMalformed < StandardError; end
    class RequestTooLarge  < StandardError; end

    Request = Struct.new(:method, :path, :headers, :body, keyword_init: true)

    class BufferedReader
      MAX_LINE_BYTES = 16 * 1024

      def initialize(io, timeout)
        @io      = io
        @timeout = timeout
        @buffer  = String.new.force_encoding(Encoding::BINARY)
      end

      def readline_crlf
        loop do
          if (idx = @buffer.index("\r\n"))
            line = @buffer.byteslice(0, idx + 2)
            @buffer = @buffer.byteslice(idx + 2, @buffer.bytesize - (idx + 2)) || "".b
            return line
          end
          raise RequestMalformed, "line too long" if @buffer.bytesize > MAX_LINE_BYTES
          return nil unless fill_buffer
        end
      end

      def read_exactly(n)
        while @buffer.bytesize < n
          fill_buffer or raise RequestMalformed, "unexpected EOF in body"
        end
        result  = @buffer.byteslice(0, n)
        @buffer = @buffer.byteslice(n, @buffer.bytesize - n) || "".b
        result
      end

      private

      def fill_buffer
        loop do
          ready = IO.select([@io], nil, nil, @timeout)
          raise RequestMalformed, "read timeout" unless ready
          chunk = @io.read_nonblock(4096, exception: false)
          case chunk
          when :wait_readable
            next
          when nil
            return false # EOF
          else
            @buffer << chunk.b
            return true
          end
        end
      end
    end

    def read_request(client)
      reader = BufferedReader.new(client, READ_TIMEOUT)
      line = reader.readline_crlf
      return nil if line.nil?
      unless line =~ /\A([A-Z]+) (\S+) HTTP\/1\.[01]\r\n\z/
        raise RequestMalformed, "invalid request line"
      end
      method = Regexp.last_match(1)
      path   = Regexp.last_match(2)

      headers = {}
      header_bytes = line.bytesize
      loop do
        header_line = reader.readline_crlf or raise RequestMalformed, "unexpected EOF in headers"
        header_bytes += header_line.bytesize
        # Enforce the size limit AFTER counting the line we just read, so a
        # final oversized line can't slip through by being the one that
        # also contains the terminating CRLF.
        raise RequestMalformed, "headers too large" if header_bytes > MAX_HEADER_BYTES
        break if header_line == "\r\n"
        unless header_line =~ /\A([^:]+):\s*(.*?)\r\n\z/
          raise RequestMalformed, "invalid header line"
        end
        headers[Regexp.last_match(1).downcase] = Regexp.last_match(2)
      end

      length = (headers["content-length"] || "0").to_i
      raise RequestTooLarge if length > MAX_BODY_BYTES

      body = length.positive? ? reader.read_exactly(length) : ""
      Request.new(method: method, path: path, headers: headers, body: body)
    end

    def write_response(client, status, body_hash)
      body = JSON.generate(body_hash)
      reason = STATUS_REASONS[status] || "Status"
      client.write(
        "HTTP/1.1 #{status} #{reason}\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n" \
        "\r\n" \
        "#{body}"
      )
    rescue Errno::EPIPE, Errno::ECONNRESET
      # Client gave up before we finished. Not our problem.
    end

    # ─── routing ───

    def dispatch(request)
      method = request.method
      path   = request.path.split("?", 2).first

      case
      when method == "GET" && path == "/healthz"
        handle_healthz(request)
      when method == "GET" && path == "/status"
        handle_status(request)
      when method == "POST" && path == "/invoke"
        handle_invoke(request)
      when method == "POST" && path == "/profiles/prune"
        handle_prune_profiles(request)
      when path.start_with?("/cancel/")
        return method_not_allowed unless method == "POST"
        handle_cancel(request, path[("/cancel/".length)..])
      when path == "/healthz" || path == "/status" || path == "/invoke" || path == "/profiles/prune" || path.start_with?("/cancel/")
        method_not_allowed
      else
        [404, { "error" => "not found" }]
      end
    end

    def handle_healthz(_req)
      [200, {
        "ok"            => true,
        "in_flight"     => current_in_flight_count,
        "shutting_down" => @shutting_down
      }]
    end

    def handle_status(req)
      return unauthorized unless authenticated?(req)
      entries = @in_flight_mutex.synchronize do
        @in_flight.values.map do |e|
          {
            "run_id"      => e[:run_id],
            "profile_key" => e[:profile_key],
            "started_at"  => e[:started_at].iso8601,
            "elapsed_ms"  => ((Time.now - e[:started_at]) * 1000).to_i
          }
        end
      end
      [200, { "in_flight" => entries }]
    end

    def handle_invoke(req)
      return [503, { "error" => "server shutting down" }] if @shutting_down
      return unauthorized unless authenticated?(req)

      body = parse_json_body(req)
      return [400, { "error" => "invalid or missing JSON body" }] if body.nil?

      begin
        request = InvokeRequest.from_hash(body, workflows_dir: @runner.workflows_dir)
      rescue InvokeError => e
        return [e.status_code, { "error" => e.message }]
      end

      registered = @in_flight_mutex.synchronize do
        next false if @in_flight.key?(request.run_id)
        @in_flight[request.run_id] = {
          run_id:      request.run_id,
          profile_key: request.profile_key,
          started_at:  Time.now,
          pid:         nil,
          pgid:        nil
        }
        true
      end
      return [409, { "error" => "run_id already in flight" }] unless registered

      result = nil
      error  = nil

      @invoke_mutex.synchronize do
        begin
          result = @runner.run(request) do |pid, pgid|
            @in_flight_mutex.synchronize do
              entry = @in_flight[request.run_id]
              if entry
                entry[:pid]  = pid
                entry[:pgid] = pgid
              end
            end
          end
        rescue InvokeError => e
          error = e
        rescue StandardError => e
          log_exception("invoke", e)
          error = InvokeError.new(:server_error, "#{e.class}: #{e.message}")
        ensure
          @in_flight_mutex.synchronize { @in_flight.delete(request.run_id) }
        end
      end

      return [error.status_code, { "error" => error.message }] if error

      [200, {
        "run_id"      => result.run_id,
        "exit_code"   => result.exit_code,
        "error_kind"  => result.error_kind,
        "duration_ms" => result.duration_ms,
        "artifacts"   => result.artifacts.map(&:to_h),
        "log_path"    => result.log_path,
        "warnings"    => result.warnings
      }]
    end

    def handle_log(client, req, run_id)
      unless authenticated?(req)
        return write_response(client, 401, { "error" => "missing or invalid bearer token" })
      end

      unless run_id =~ RUN_ID_PATTERN
        return write_response(client, 404, { "error" => "run_id not found" })
      end

      log_path = File.join(@runner.runs_dir, run_id, "log")
      unless File.file?(log_path)
        return write_response(client, 404, { "error" => "log not found for run_id=#{run_id}" })
      end

      # realpath guard: reject if the resolved file isn't under runs_dir
      # (belt-and-braces against any future symlink shenanigans in the runs dir).
      begin
        runs_real = File.realpath(@runner.runs_dir)
        file_real = File.realpath(log_path)
      rescue Errno::ENOENT
        return write_response(client, 404, { "error" => "log not found" })
      end
      unless file_real.start_with?(runs_real + File::SEPARATOR)
        return write_response(client, 404, { "error" => "log path escapes runs dir" })
      end

      size = File.size(log_path)
      range = parse_range_header(req.headers["range"], size)

      case range
      when :bad_range
        write_response(client, 400, { "error" => "malformed Range header" })
      when :not_satisfiable
        write_range_not_satisfiable(client, size)
      when nil
        stream_log(client, log_path, 0, size - 1, size, partial: false)
      else
        first, last = range
        stream_log(client, log_path, first, last, size, partial: true)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET
      # Client went away mid-stream. Not our problem.
    end

    # Returns:
    #   nil              — no Range header (client wants the whole file)
    #   [first, last]    — inclusive byte range, 0-indexed
    #   :not_satisfiable — Range is well-formed but can't be satisfied
    #   :bad_range       — Range header is malformed
    #
    # Supported forms: "bytes=N-", "bytes=N-M", "bytes=-N" (last N bytes).
    def parse_range_header(header, size)
      return nil if header.nil? || header.empty?
      return :bad_range unless header =~ /\Abytes=(\d*)-(\d*)\z/
      first_s = Regexp.last_match(1)
      last_s  = Regexp.last_match(2)

      return :bad_range if first_s.empty? && last_s.empty?

      # Empty file: any numeric Range is not satisfiable.
      return :not_satisfiable if size.zero?

      if first_s.empty?
        # suffix form: last N bytes
        suffix = last_s.to_i
        return :not_satisfiable if suffix.zero?
        first = [size - suffix, 0].max
        last  = size - 1
      elsif last_s.empty?
        first = first_s.to_i
        return :not_satisfiable if first >= size
        last = size - 1
      else
        first = first_s.to_i
        last  = last_s.to_i
        return :not_satisfiable if first > last || first >= size
        last = [last, size - 1].min
      end

      [first, last]
    end

    def stream_log(client, path, first, last, size, partial:)
      length = size.zero? ? 0 : (last - first + 1)
      status = partial ? 206 : 200

      headers = [
        "HTTP/1.1 #{status} #{STATUS_REASONS[status]}",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Length: #{length}",
        "Accept-Ranges: bytes",
        "Cache-Control: no-store",
        "Connection: close"
      ]
      headers << "Content-Range: bytes #{first}-#{last}/#{size}" if partial

      client.write(headers.join("\r\n") + "\r\n\r\n")
      return if length.zero?

      File.open(path, "rb") do |f|
        f.seek(first) if first.positive?
        remaining = length
        while remaining.positive?
          chunk = f.read([remaining, LOG_CHUNK_BYTES].min)
          break if chunk.nil? || chunk.empty?
          client.write(chunk)
          remaining -= chunk.bytesize
        end
      end
    end

    def write_range_not_satisfiable(client, size)
      body = JSON.generate({ "error" => "range not satisfiable" })
      client.write(
        "HTTP/1.1 416 Range Not Satisfiable\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Content-Range: bytes */#{size}\r\n" \
        "Connection: close\r\n" \
        "\r\n" \
        "#{body}"
      )
    end

    # POST /profiles/prune
    #
    # Body must contain exactly one of:
    #   { "profile_key": "<key>" }  — delete one profile directory
    #   { "prefix":      "<str>" }  — delete every profile dir whose name starts with <str>
    #
    # Acquires the invoke mutex, so a prune can never race an in-flight
    # Chrome session (v1 serialization). Deleted paths are charset-validated
    # and realpath-guarded against escaping the chrome profile root.
    def handle_prune_profiles(req)
      return unauthorized unless authenticated?(req)

      body = parse_json_body(req)
      return [400, { "error" => "invalid or missing JSON body" }] if body.nil?

      profile_key = body["profile_key"]
      prefix      = body["prefix"]

      if profile_key && prefix
        return [400, { "error" => "provide exactly one of profile_key or prefix, not both" }]
      end
      if profile_key.nil? && prefix.nil?
        return [400, { "error" => "provide one of profile_key or prefix" }]
      end

      root = @runner.chrome_profile_root

      begin
        deleted = @invoke_mutex.synchronize do
          if profile_key
            prune_exact_profile(root, profile_key)
          else
            prune_profiles_by_prefix(root, prefix)
          end
        end
      rescue InvokeError => e
        return [e.status_code, { "error" => e.message }]
      end

      [200, { "deleted" => deleted, "count" => deleted.size }]
    end

    PROFILE_KEY_PATTERN_SRV = /\A[A-Za-z0-9_.\-]{1,128}\z/.freeze

    def prune_exact_profile(root, profile_key)
      unless profile_key.is_a?(String) && profile_key =~ PROFILE_KEY_PATTERN_SRV
        raise InvokeError.new(:bad_request,
          "profile_key has invalid characters or is too long")
      end

      target = safe_profile_path(root, profile_key)
      raise InvokeError.new(:bad_request, "profile_key escapes the profile root") if target.nil?
      return [] unless Dir.exist?(target)

      FileUtils.rm_rf(target)
      [profile_key]
    end

    def prune_profiles_by_prefix(root, prefix)
      unless prefix.is_a?(String) && !prefix.empty? && prefix =~ PROFILE_KEY_PATTERN_SRV
        raise InvokeError.new(:bad_request,
          "prefix must be a non-empty string of [A-Za-z0-9_.-] up to 128 chars")
      end

      return [] unless Dir.exist?(root)
      root_real = File.realpath(root)

      deleted = []
      Dir.each_child(root).sort.each do |name|
        next unless name.start_with?(prefix)
        # Defense-in-depth: skip anything that isn't a plain directory or
        # whose realpath escapes the profile root (symlink tricks, etc.).
        target = File.join(root, name)
        next unless File.directory?(target) && !File.symlink?(target)
        real = File.realpath(target) rescue nil
        next if real.nil? || !real.start_with?(root_real + File::SEPARATOR)

        FileUtils.rm_rf(target)
        deleted << name
      end
      deleted
    end

    def safe_profile_path(root, key)
      candidate = File.expand_path(File.join(root, key))
      root_abs  = File.expand_path(root)
      return nil unless candidate.start_with?(root_abs + File::SEPARATOR)
      candidate
    end

    def handle_cancel(req, run_id)
      return unauthorized unless authenticated?(req)
      run_id = run_id.to_s.strip
      return [400, { "error" => "missing run_id in path" }] if run_id.empty?

      entry = @in_flight_mutex.synchronize { @in_flight[run_id]&.dup }
      return [404, { "error" => "run_id not in flight or not yet spawned" }] unless entry && entry[:pgid]

      begin
        Process.kill("-TERM", entry[:pgid])
      rescue Errno::ESRCH
        # already gone
      end

      Thread.new(entry[:pgid]) do |pgid|
        sleep CANCEL_GRACE_SECONDS
        Process.kill("-KILL", pgid) rescue nil
      end

      [202, { "accepted" => true, "run_id" => run_id }]
    end

    # ─── helpers ───

    def authenticated?(req)
      return true if @invoke_token.nil?
      header = req.headers["authorization"].to_s
      return false unless header.start_with?("Bearer ")
      provided = header.sub(/\ABearer\s+/, "").strip
      secure_compare(provided, @invoke_token)
    end

    def secure_compare(a, b)
      return false if a.bytesize != b.bytesize
      diff = 0
      a.each_byte.with_index { |byte, i| diff |= byte ^ b.getbyte(i) }
      diff.zero?
    end

    def parse_json_body(req)
      return nil if req.body.nil? || req.body.empty?
      JSON.parse(req.body)
    rescue JSON::ParserError
      nil
    end

    def unauthorized
      [401, { "error" => "missing or invalid bearer token" }]
    end

    def method_not_allowed
      [405, { "error" => "method not allowed" }]
    end

    def current_in_flight_count
      @in_flight_mutex.synchronize { @in_flight.size }
    end

    def log(msg)
      return unless @logger
      @logger.puts("[invoke-server] #{msg}")
      @logger.flush if @logger.respond_to?(:flush)
    end

    def log_exception(context, error)
      log("error in #{context}: #{error.class}: #{error.message}")
      error.backtrace&.first(12)&.each { |line| log("  #{line}") }
    end
  end
end
