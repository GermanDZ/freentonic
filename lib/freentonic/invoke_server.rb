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

    # Cap on concurrent connection handler threads. /invoke is serialized by
    # @invoke_mutex anyway; this cap protects us from log-tail clients (or
    # slow/stuck clients) that don't. When exceeded, new connections get a
    # 503 with Retry-After and the socket closes.
    MAX_CONCURRENT_CONNECTIONS = 64

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
      410 => "Gone",
      413 => "Payload Too Large",
      416 => "Range Not Satisfiable",
      422 => "Unprocessable Entity",
      500 => "Internal Server Error",
      503 => "Service Unavailable",
      504 => "Gateway Timeout"
    }.freeze

    RUN_ID_PATTERN     = /\A[A-Za-z0-9_\-:.]{1,64}\z/.freeze
    PROMPT_ID_PATTERN  = /\Ap_[A-Fa-f0-9]{4,64}\z/.freeze
    LOG_CHUNK_BYTES    = 64 * 1024

    def initialize(
      runner:,
      invoke_token: nil,
      listen_addr: DEFAULT_ADDR,
      listen_port: DEFAULT_PORT,
      logger: $stdout,
      max_concurrent_connections: MAX_CONCURRENT_CONNECTIONS
    )
      @runner          = runner
      @invoke_token    = (invoke_token && !invoke_token.empty?) ? invoke_token : nil
      @listen_addr     = listen_addr
      @listen_port     = listen_port
      @logger          = logger

      @invoke_mutex        = Mutex.new
      @in_flight_mutex     = Mutex.new
      @in_flight           = {}
      @shutting_down       = false
      @server_socket       = nil
      @connection_mutex    = Mutex.new
      @active_connections  = 0
      @max_connections     = max_concurrent_connections
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

        admitted = @connection_mutex.synchronize do
          if @active_connections >= @max_connections
            false
          else
            @active_connections += 1
            true
          end
        end

        if admitted
          Thread.new(client) do |c|
            begin
              handle_connection(c)
            ensure
              @connection_mutex.synchronize { @active_connections -= 1 }
            end
          end
        else
          refuse_over_capacity(client)
        end
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

    # Accessor for the concurrency-cap counter. Exposed so tests can block
    # until a slow connection has actually been accepted (rather than
    # guessing with sleep). Thread-safe via the connection mutex.
    def active_connection_count
      @connection_mutex.synchronize { @active_connections }
    end

    private

    # ─── HTTP wire protocol ───

    # Short, body-less 503 when the concurrency cap is hit. We intentionally
    # don't spin up a full handler thread — that would defeat the cap. Just
    # write a minimal response directly and close.
    #
    # SO_LINGER(1, 2) makes close() wait up to 2 s for the kernel to flush
    # our 503 to the client before the socket is torn down. Without it,
    # close() with unread bytes in the receive buffer (the client's GET)
    # can send a TCP RST, and the client sees ECONNRESET instead of 503.
    def refuse_over_capacity(client)
      client.sync = true
      client.write(
        "HTTP/1.1 503 Service Unavailable\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: 0\r\n" \
        "Retry-After: 1\r\n" \
        "Connection: close\r\n" \
        "\r\n"
      )
      # Half-close the write side (FIN) so the client sees EOF cleanly.
      # Then drain anything the client sent so the final close() doesn't
      # RST. Without this dance, a client whose request is still buffered
      # by the kernel when we close() sees ECONNRESET instead of our 503.
      begin
        client.shutdown(Socket::SHUT_WR)
      rescue StandardError
        # ok
      end
      deadline = Time.now + 0.5
      while Time.now < deadline
        ready = IO.select([client], nil, nil, 0.1)
        break unless ready
        begin
          chunk = client.read_nonblock(4096)
          break if chunk.nil? || chunk.empty?
        rescue IO::WaitReadable, EOFError, Errno::ECONNRESET, StandardError
          break
        end
      end
    rescue StandardError
      # client gave up / network blip — not our problem
    ensure
      client.close rescue nil
    end

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

      if (match = path.match(%r{\A/runs/([^/]+)/recording\z}))
        if request.method == "GET"
          handle_recording(client, request, match[1])
        else
          write_response(client, 405, { "error" => "method not allowed" })
        end
        return
      end

      if (match = path.match(%r{\A/runs/([^/]+)/prompts\z}))
        if request.method == "GET"
          status, body = handle_list_prompts(request, match[1])
          write_response(client, status, body)
        else
          write_response(client, 405, { "error" => "method not allowed" })
        end
        return
      end

      if (match = path.match(%r{\A/runs/([^/]+)/prompts/([^/]+)\z}))
        if request.method == "POST"
          status, body = handle_submit_prompt(request, match[1], match[2])
          write_response(client, status, body)
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

      # We don't support chunked transfer encoding; reject it explicitly
      # rather than silently falling back to Content-Length, which would
      # be a request-smuggling shape if a proxy in front of us disagreed
      # about framing.
      if (te = headers["transfer-encoding"]) && !te.strip.empty?
        raise RequestMalformed, "Transfer-Encoding not supported"
      end

      length = parse_content_length(headers["content-length"])
      raise RequestTooLarge if length > MAX_BODY_BYTES

      body = length.positive? ? reader.read_exactly(length) : ""
      Request.new(method: method, path: path, headers: headers, body: body)
    end

    def parse_content_length(raw)
      return 0 if raw.nil? || raw.strip.empty?
      # Strict: digits only, no sign, no whitespace. Ruby's String#to_i would
      # silently accept "abc" → 0 (body skipped) or "-5" → -5 (body skipped).
      unless raw.strip =~ /\A\d+\z/
        raise RequestMalformed, "invalid Content-Length: #{raw.inspect}"
      end
      raw.strip.to_i
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

    # GET /runs/{run_id}/recording
    #
    # Serves <run_dir>/recording.jsonl as text/plain. No Range support
    # — recordings are short (a single browse session, on the order of
    # tens of KB) and the simplefreen UI parses the whole thing in one
    # shot. 404 if no recording exists for this run_id (i.e. the run
    # was not started in recording mode, or never produced any
    # events).
    def handle_recording(client, req, run_id)
      unless authenticated?(req)
        return write_response(client, 401, { "error" => "missing or invalid bearer token" })
      end
      unless run_id =~ RUN_ID_PATTERN
        return write_response(client, 404, { "error" => "run_id not found" })
      end

      file_path = File.join(@runner.runs_dir, run_id, "recording.jsonl")
      unless File.file?(file_path)
        return write_response(client, 404, { "error" => "recording not found for run_id=#{run_id}" })
      end

      # Same realpath escape guard as handle_log — defends against any
      # symlink shenanigans inside the runs dir.
      begin
        runs_real = File.realpath(@runner.runs_dir)
        file_real = File.realpath(file_path)
      rescue Errno::ENOENT
        return write_response(client, 404, { "error" => "recording not found" })
      end
      unless file_real.start_with?(runs_real + File::SEPARATOR)
        return write_response(client, 404, { "error" => "recording path escapes runs dir" })
      end

      body = File.binread(file_path)
      headers = [
        "HTTP/1.1 200 OK",
        "Content-Type: application/x-ndjson; charset=utf-8",
        "Content-Length: #{body.bytesize}",
        "Cache-Control: no-store",
        "Connection: close"
      ]
      client.write(headers.join("\r\n") + "\r\n\r\n")
      client.write(body) unless body.empty?
    rescue Errno::EPIPE, Errno::ECONNRESET
      # Client went away. Not our problem.
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

    # GET /runs/{run_id}/prompts
    #
    # Returns 200 with the list of prompts whose request file exists and
    # whose response file does not. Used by HTTP clients to discover when
    # a workflow is paused waiting for an out-of-band 2FA / SMS code.
    def handle_list_prompts(req, run_id)
      return unauthorized unless authenticated?(req)
      return [404, { "error" => "run_id not found" }] unless run_id =~ RUN_ID_PATTERN

      prompts_dir = run_subpath(run_id, "prompts")
      return [200, { "run_id" => run_id, "prompts" => [] }] unless prompts_dir && Dir.exist?(prompts_dir)

      pending = []
      Dir.each_child(prompts_dir).sort.each do |name|
        next unless name.end_with?(".request.json")
        prompt_id = name.sub(/\.request\.json\z/, "")
        next unless prompt_id =~ PROMPT_ID_PATTERN
        response_file = File.join(prompts_dir, "#{prompt_id}.response.json")
        next if File.exist?(response_file)

        request_path = File.join(prompts_dir, name)
        begin
          payload = JSON.parse(File.read(request_path))
        rescue StandardError
          next
        end
        pending << {
          "prompt_id"  => payload["prompt_id"],
          "kind"       => payload["kind"],
          "message"    => payload["message"],
          "mask"       => payload["mask"],
          "created_at" => payload["created_at"],
          "expires_at" => payload["expires_at"]
        }
      end

      [200, { "run_id" => run_id, "prompts" => pending }]
    end

    # POST /runs/{run_id}/prompts/{prompt_id}
    #
    # Body: { "value": "..." } for kind=input, or {} for kind=confirm/await.
    # 204 on success, 404 if unknown, 409 if already answered, 410 if
    # expired, 400 on shape errors.
    def handle_submit_prompt(req, run_id, prompt_id)
      return unauthorized unless authenticated?(req)
      return [404, { "error" => "run_id not found" }] unless run_id =~ RUN_ID_PATTERN
      return [404, { "error" => "prompt_id not found" }] unless prompt_id =~ PROMPT_ID_PATTERN

      prompts_dir = run_subpath(run_id, "prompts")
      return [404, { "error" => "no prompts directory for run_id=#{run_id}" }] unless prompts_dir && Dir.exist?(prompts_dir)

      request_path  = File.join(prompts_dir, "#{prompt_id}.request.json")
      response_path = File.join(prompts_dir, "#{prompt_id}.response.json")

      return [404, { "error" => "prompt not found" }] unless File.file?(request_path)
      return [409, { "error" => "prompt already answered" }] if File.exist?(response_path)

      begin
        request_payload = JSON.parse(File.read(request_path))
      rescue StandardError
        return [500, { "error" => "could not read prompt request" }]
      end

      if (expires_at = request_payload["expires_at"])
        begin
          if Time.iso8601(expires_at) < Time.now
            return [410, { "error" => "prompt expired" }]
          end
        rescue ArgumentError
          # malformed expires_at; treat as not-expired and let the runner's
          # own deadline catch it. We avoid 500-ing on a stale-on-disk file.
        end
      end

      body = parse_json_body(req) || {}

      response_payload = { "prompt_id" => prompt_id, "submitted_at" => Time.now.utc.iso8601 }
      case request_payload["kind"]
      when "input"
        value = body["value"]
        unless value.is_a?(String) && !value.empty?
          return [400, { "error" => "missing or empty value for input prompt" }]
        end
        response_payload["value"] = value
      when "confirm", "await"
        # `await` prompts normally resolve on their own (the runner withdraws
        # the request when its condition fires); this branch handles the
        # operator clicking the fallback button before that happens. Same
        # shape as confirm — no value to carry.
        response_payload["confirmed"] = true
      else
        return [500, { "error" => "unknown prompt kind in stored request" }]
      end

      tmp = "#{response_path}.tmp.#{Process.pid}.#{rand(1 << 32)}"
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
          f.write(JSON.generate(response_payload))
        end
        # rename(2) fails if the destination already exists on most
        # filesystems? Actually POSIX rename overwrites. We've already
        # checked above (and the runner consumes single-shot), so a race
        # against a second concurrent POST is the only way two writes
        # collide; the second overwrite is harmless because the value
        # is the same shape, but we still want single-use semantics.
        # File.link gives us atomic "fail if exists":
        begin
          File.link(tmp, response_path)
          File.unlink(tmp)
        rescue Errno::EEXIST
          File.unlink(tmp) rescue nil
          return [409, { "error" => "prompt already answered" }]
        end
      rescue StandardError => e
        File.unlink(tmp) rescue nil
        log_exception("submit_prompt", e)
        return [500, { "error" => "could not record prompt response" }]
      end

      [200, { "ok" => true, "prompt_id" => prompt_id }]
    end

    # Resolve <runs_dir>/<run_id>/<sub> with a realpath escape guard.
    # Returns nil if the path doesn't exist or escapes the runs root.
    def run_subpath(run_id, sub)
      return nil unless run_id =~ RUN_ID_PATTERN
      candidate = File.join(@runner.runs_dir, run_id, sub)
      return nil unless File.exist?(candidate)
      begin
        runs_real = File.realpath(@runner.runs_dir)
        real      = File.realpath(candidate)
      rescue Errno::ENOENT
        return nil
      end
      return nil unless real == runs_real || real.start_with?(runs_real + File::SEPARATOR)
      candidate
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

      # Grace window, then SIGKILL the whole pgroup — BUT only after
      # verifying the original pid is still alive and still in the same
      # pgroup. Without this re-check, a child that exited during the
      # grace and whose pid was recycled by the OS could be killed by
      # mistake, along with whichever unrelated process now sits in the
      # recycled pgroup.
      Thread.new(entry[:pid], entry[:pgid]) do |pid, pgid|
        sleep CANCEL_GRACE_SECONDS
        begin
          current_pgid = Process.getpgid(pid)
          Process.kill("-KILL", pgid) if current_pgid == pgid
        rescue Errno::ESRCH
          # Original child already exited — nothing to KILL.
        rescue StandardError
          # Any other kill/getpgid failure: swallow; we're best-effort here.
        end
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
