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
  # Auth: if @invoke_tokens is non-empty, clients must send
  #   Authorization: Bearer <token>
  # matching any one of them. Missing/incorrect tokens return 401. Accepting a
  # set (rather than a single token) lets an operator roll a new token out to
  # clients before retiring the old one — zero-downtime rotation without a
  # simultaneous client cutover.
  class InvokeServer
    DEFAULT_ADDR = "127.0.0.1"
    DEFAULT_PORT = 7878

    MAX_BODY_BYTES  = 1 * 1024 * 1024 # 1 MiB
    MAX_HEADER_BYTES = 16 * 1024
    READ_TIMEOUT    = 30
    # Absolute wall-clock budget for reading a whole request (accept → end of
    # body), independent of READ_TIMEOUT's per-select idle window. Without it,
    # a client trickling one byte per (READ_TIMEOUT - 1)s resets the idle
    # window forever and pins a connection slot without ever authenticating —
    # enough such sockets 503 everything, including /healthz.
    REQUEST_READ_DEADLINE = 30

    # Cap on concurrent connection handler threads. /invoke is serialized by
    # @invoke_mutex anyway; this cap protects us from log-tail clients (or
    # slow/stuck clients) that don't. When exceeded, new connections get a
    # 503 with Retry-After and the socket closes.
    MAX_CONCURRENT_CONNECTIONS = 64

    CANCEL_GRACE_SECONDS = 10

    # /invoke is async: it validates + enqueues, then returns 202 immediately.
    # A single worker thread pops the queue and runs one invoke at a time under
    # @invoke_mutex (v1's strict serialization is preserved). Two bounds keep the
    # registry from growing without limit:
    #   MAX_QUEUED_RUNS   — accepted-but-not-yet-finished runs; over it, 503.
    #   MAX_RETAINED_RUNS — finished runs kept in memory so GET /runs/:id can
    #                       still report a result after completion. The oldest
    #                       are evicted FIFO; a caller that misses the window
    #                       falls back to reading artifacts off the runs dir.
    MAX_QUEUED_RUNS   = 128
    MAX_RETAINED_RUNS = 256

    # Pushed onto @run_queue by drain to make the worker exit its pop loop.
    WORKER_SHUTDOWN = :__worker_shutdown__

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

    # On shutdown, how long to wait for the in-flight invoke's handler thread
    # to drain after we SIGTERM its child process group. Sized to comfortably
    # cover the runner's own SIGTERM→SIGKILL grace plus Chrome cleanup, so a
    # `docker stop -t` honoring this window lets the run tear down cleanly
    # instead of dying by container SIGKILL mid-Process.wait2 (which risks
    # Chrome-profile corruption and drops the blocked /invoke response).
    SHUTDOWN_DRAIN_SECONDS = 20

    # Assemble the accepted bearer-token set from every configured source and
    # return a deduped list. Sources (all optional, all unioned):
    #
    #   cli_tokens     — values passed as --invoke-token (repeatable)
    #   cli_files      — paths passed as --invoke-token-file (repeatable)
    #   env_token      — FREENTONIC_INVOKE_TOKEN, comma-separated for >1 token
    #   env_token_file — FREENTONIC_INVOKE_TOKEN_FILE, one token per line
    #
    # A *_FILE source keeps the secret off the process argv and out of
    # `docker inspect` (only the path is visible), and holding several tokens
    # at once is what makes zero-downtime rotation possible: publish the new
    # token, cut clients over at their own pace, then drop the old one.
    #
    # File format: one token per line; blank lines and lines whose first
    # non-space char is `#` are ignored; surrounding whitespace is stripped.
    def self.load_tokens(cli_tokens: [], cli_files: [], env_token: nil, env_token_file: nil)
      tokens = []
      tokens.concat(Array(cli_tokens))
      tokens.concat(env_token.to_s.split(",")) unless env_token.nil?
      files = Array(cli_files)
      files << env_token_file unless env_token_file.nil? || env_token_file.empty?
      files.each { |path| tokens.concat(tokens_from_file(path)) }
      tokens.map { |t| t.to_s.strip }.reject(&:empty?).uniq
    end

    def self.tokens_from_file(path)
      unless File.file?(path)
        raise UserError, "invoke-token file not found: #{path}"
      end
      File.readlines(path, chomp: true).reject do |line|
        stripped = line.strip
        stripped.empty? || stripped.start_with?("#")
      end
    end

    def initialize(
      runner:,
      invoke_tokens: nil,
      listen_addr: DEFAULT_ADDR,
      listen_port: DEFAULT_PORT,
      logger: $stdout,
      max_concurrent_connections: MAX_CONCURRENT_CONNECTIONS,
      max_queued_runs:   MAX_QUEUED_RUNS,
      max_retained_runs: MAX_RETAINED_RUNS
    )
      @runner          = runner
      # Normalize to a frozen list of non-empty tokens. Empty ⇒ auth disabled.
      @invoke_tokens   = Array(invoke_tokens).map { |t| t.to_s }.reject(&:empty?).uniq.freeze
      @listen_addr     = listen_addr
      @listen_port     = listen_port
      @logger          = logger
      @max_queued_runs   = max_queued_runs
      @max_retained_runs = max_retained_runs

      @invoke_mutex        = Mutex.new
      @in_flight_mutex     = Mutex.new
      @in_flight           = {}
      # Run-lifecycle registry, guarded by @runs_mutex. Outlives @in_flight
      # (which only tracks queued+running work) so GET /runs/:id can report a
      # result after the run leaves the in-flight set. @completed_order is the
      # FIFO eviction index over terminal records.
      @runs_mutex          = Mutex.new
      @runs                = {}
      @completed_order     = []
      # Cumulative, process-lifetime run counters exposed at GET /metrics. Guarded
      # by its own mutex so the hot finalize path never contends with @runs_mutex
      # readers. error_kind buckets mirror InvokeRunner::ERROR_KINDS plus the
      # server-side terminal states (error/cancelled) a runner never reports.
      @metrics_mutex       = Mutex.new
      @metrics             = {
        runs_total:       0,
        duration_ms_total: 0,
        by_error_kind:    Hash.new(0),
        by_status:        Hash.new(0)
      }
      @run_queue           = Thread::Queue.new
      @worker              = nil
      @shutting_down       = false
      @server_socket       = nil
      @connection_mutex    = Mutex.new
      @active_connections  = 0
      @max_connections     = max_concurrent_connections
      # Live handler threads, guarded by @connection_mutex. Tracked so shutdown
      # can join in-flight work instead of abandoning it when start() returns.
      @handler_threads     = []
    end

    def start
      @server_socket = TCPServer.new(@listen_addr, @listen_port)
      @worker        = Thread.new { run_worker }
      log "listening on http://#{@listen_addr}:#{@listen_port}" \
          "#{@invoke_tokens.empty? ? " (auth: OPEN — no token set)" : " (auth: #{@invoke_tokens.size} bearer token#{@invoke_tokens.size == 1 ? "" : "s"})"}"

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
          thread = Thread.new(client) do |c|
            begin
              handle_connection(c)
            ensure
              @connection_mutex.synchronize { @active_connections -= 1 }
            end
          end
          @connection_mutex.synchronize do
            # Prune completed threads so the list can't grow unbounded over the
            # server's lifetime, then track the newcomer.
            @handler_threads.select!(&:alive?)
            @handler_threads << thread
          end
        else
          refuse_over_capacity(client)
        end
      end
    ensure
      @server_socket&.close rescue nil
      drain_handlers
    end

    # Safe to call from a signal handler.
    def shutdown
      @shutting_down = true
      # Closing the server socket wakes accept() with an error.
      @server_socket&.close rescue nil
    end

    # Graceful drain, run from start()'s ensure once the accept loop exits.
    # SIGTERM any in-flight child process group (the runner spawns children in
    # their own group via pgroup: true, so tini/-g in the container can't reach
    # them — the server must), then wait a bounded window for the handler
    # threads to finish: the runner's wait loop reaps the terminated child,
    # cleans up Chrome, and delivers the /invoke response before returning.
    # Threads that don't drain in time (e.g. slow-drip readers) are abandoned;
    # process teardown reaps them.
    def drain_handlers
      terminate_in_flight_groups

      deadline = Time.now + SHUTDOWN_DRAIN_SECONDS

      # Wake the worker so it stops popping the queue and exits. execute_run
      # already refuses to start a fresh child once @shutting_down is set, so
      # anything still queued behind the running invoke is aborted, not run.
      if @worker
        @run_queue << WORKER_SHUTDOWN
        remaining = deadline - Time.now
        @worker.join(remaining) if remaining.positive?
      end

      threads = @connection_mutex.synchronize { @handler_threads.dup }
      threads.each do |t|
        remaining = deadline - Time.now
        break if remaining <= 0
        t.join(remaining)
      end

      # Any run still queued (worker abandoned mid-drain, or never got to it)
      # is reported as aborted rather than left dangling in "queued" forever.
      abort_pending_runs("server shutting down")
    end

    def terminate_in_flight_groups
      pgids = @in_flight_mutex.synchronize do
        @in_flight.values.map { |e| e[:pgid] }.compact
      end
      pgids.each do |pgid|
        begin
          Process.kill("-TERM", pgid)
          log "shutdown: sent SIGTERM to in-flight process group #{pgid}"
        rescue Errno::ESRCH
          # already gone
        rescue StandardError => e
          log "shutdown: failed to signal process group #{pgid}: #{e.class}: #{e.message}"
        end
      end
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
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      method  = "-"
      path    = "-"
      status  = nil
      begin
        request = read_request(client)
      rescue RequestTooLarge
        status = write_response(client, 413, { "error" => "payload too large" })
        return
      rescue RequestMalformed => e
        status = write_response(client, 400, { "error" => "malformed request: #{e.message}" })
        return
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET, Errno::ETIMEDOUT
        return
      end
      # A clean EOF with no request line (nil) means the peer opened and closed
      # without speaking — nothing to serve and nothing worth an access line.
      return unless request

      method = request.method
      path   = request.path.split("?", 2).first
      status = serve(client, request)
    rescue StandardError => e
      log_exception("connection", e)
      status = 500
      begin
        write_response(client, 500, { "error" => "internal server error" })
      rescue StandardError
        nil
      end
    ensure
      log_access(method, path, status, started) if status
      client.close rescue nil
    end

    # Route one request to its handler and return the numeric HTTP status that
    # was written (for the access log). The log/recording routes stream bytes
    # directly to the socket (large bodies + Range support), so they can't ride
    # the [status, hash] JSON dispatcher and are matched here first.
    def serve(client, request)
      path = request.path.split("?", 2).first

      if (match = path.match(%r{\A/runs/([^/]+)/log\z}))
        return request.method == "GET" ? handle_log(client, request, match[1]) : write_method_not_allowed(client)
      end

      if (match = path.match(%r{\A/runs/([^/]+)/recording\z}))
        return request.method == "GET" ? handle_recording(client, request, match[1]) : write_method_not_allowed(client)
      end

      if (match = path.match(%r{\A/runs/([^/]+)/prompts\z}))
        return write_method_not_allowed(client) unless request.method == "GET"
        status, body = handle_list_prompts(request, match[1])
        return write_response(client, status, body)
      end

      if (match = path.match(%r{\A/runs/([^/]+)/prompts/([^/]+)\z}))
        return write_method_not_allowed(client) unless request.method == "POST"
        status, body = handle_submit_prompt(request, match[1], match[2])
        return write_response(client, status, body)
      end

      status, body = dispatch(request)
      write_response(client, status, body)
    end

    def write_method_not_allowed(client)
      write_response(client, 405, { "error" => "method not allowed" })
    end

    # One line per served request: method, path, status, wall time. No headers,
    # no bodies, no query string — just enough to see traffic and latency
    # without ever logging a token or credential.
    def log_access(method, path, status, started_mono)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_mono) * 1000).to_i
      log("#{method} #{path} #{status} #{ms}ms")
    end

    class RequestMalformed < StandardError; end
    class RequestTooLarge  < StandardError; end

    Request = Struct.new(:method, :path, :headers, :body, keyword_init: true)

    class BufferedReader
      MAX_LINE_BYTES = 16 * 1024

      # `deadline` is a monotonic-clock instant (or nil): once passed, no
      # further blocking read is allowed, so a slow-drip client can't hold the
      # connection past REQUEST_READ_DEADLINE no matter how it paces its bytes.
      def initialize(io, timeout, deadline: nil)
        @io       = io
        @timeout  = timeout
        @deadline = deadline
        @buffer   = String.new.force_encoding(Encoding::BINARY)
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
          wait = @timeout
          if @deadline
            remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise RequestMalformed, "read deadline exceeded" if remaining <= 0
            wait = remaining if remaining < wait
          end
          ready = IO.select([@io], nil, nil, wait)
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
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REQUEST_READ_DEADLINE
      reader = BufferedReader.new(client, READ_TIMEOUT, deadline: deadline)
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

    # Returns `status` (the code it wrote) so callers — and the streaming
    # handlers that `return write_response(...)` — can propagate it to the
    # access log. The return value is the status even when the client hung up
    # mid-write: that's still what this request resolved to.
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
      status
    rescue Errno::EPIPE, Errno::ECONNRESET
      # Client gave up before we finished. Not our problem.
      status
    end

    # ─── routing ───

    def dispatch(request)
      method = request.method
      path   = request.path.split("?", 2).first
      run_status_match = path.match(%r{\A/runs/([^/]+)\z})

      case
      when method == "GET" && path == "/healthz"
        handle_healthz(request)
      when method == "GET" && path == "/status"
        handle_status(request)
      when method == "GET" && path == "/metrics"
        handle_metrics(request)
      when method == "POST" && path == "/invoke"
        handle_invoke(request)
      when method == "POST" && path == "/profiles/prune"
        handle_prune_profiles(request)
      when run_status_match
        return method_not_allowed unless method == "GET"
        handle_run_status(request, run_status_match[1])
      when path.start_with?("/cancel/")
        return method_not_allowed unless method == "POST"
        handle_cancel(request, path[("/cancel/".length)..])
      when path == "/healthz" || path == "/status" || path == "/metrics" || path == "/invoke" || path == "/profiles/prune" || path.start_with?("/cancel/")
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

    # GET /status — live view of queued + running work.
    #
    # Each entry distinguishes queued from running: a run is "queued" until the
    # worker dequeues it, "running" once its child spawns. `queued_ms` is time
    # spent waiting in the queue (it stops climbing once the run starts);
    # `elapsed_ms` is child run-time and is absent while still queued. Splitting
    # them keeps run-time from being inflated by queue wait.
    def handle_status(req)
      return unauthorized unless authenticated?(req)
      now = Time.now
      entries = @in_flight_mutex.synchronize do
        @in_flight.values.map do |e|
          running   = !e[:started_at].nil?
          queued_to = running ? e[:started_at] : now
          entry = {
            "run_id"       => e[:run_id],
            "profile_key"  => e[:profile_key],
            "status"       => running ? "running" : "queued",
            "submitted_at" => e[:submitted_at].iso8601,
            "queued_ms"    => ((queued_to - e[:submitted_at]) * 1000).to_i
          }
          if running
            entry["started_at"] = e[:started_at].iso8601
            entry["elapsed_ms"] = ((now - e[:started_at]) * 1000).to_i
          end
          entry
        end
      end
      [200, { "in_flight" => entries }]
    end

    # GET /metrics — cumulative, process-lifetime counters. Aggregate only: no
    # per-run detail, no bodies, nothing sensitive. `duration_ms_avg` is derived
    # (0 before any run finishes). Buckets: by_status (done/error/cancelled) and
    # by_error_kind (a runner's error_kind, "ok" for a clean exit, or the
    # terminal status for server-side failures/cancels).
    def handle_metrics(req)
      return unauthorized unless authenticated?(req)
      snap = @metrics_mutex.synchronize do
        {
          runs_total:        @metrics[:runs_total],
          duration_ms_total: @metrics[:duration_ms_total],
          by_error_kind:     @metrics[:by_error_kind].dup,
          by_status:         @metrics[:by_status].dup
        }
      end
      avg = snap[:runs_total].zero? ? 0 : (snap[:duration_ms_total] / snap[:runs_total])
      [200, {
        "runs_total"        => snap[:runs_total],
        "in_flight"         => current_in_flight_count,
        "duration_ms_total" => snap[:duration_ms_total],
        "duration_ms_avg"   => avg,
        "by_status"         => snap[:by_status],
        "by_error_kind"     => snap[:by_error_kind]
      }]
    end

    # GET /runs/{run_id} — lifecycle + result of one async invoke.
    #
    #   queued   → 200 {status, submitted_at}
    #   running  → 200 {status, started_at, elapsed_ms}
    #   done     → 200 {status, exit_code, error_kind, duration_ms, artifacts,
    #                   log_path, warnings, finished_at}
    #   error    → 200 {status, error, finished_at}   (server/containment failure)
    #   cancelled→ 200 {status, finished_at}
    #   unknown  → 404 (never submitted, or evicted past MAX_RETAINED_RUNS)
    #
    # 200 means "here is the run's state", not "the run succeeded" — a non-zero
    # exit_code is still reported under a 200 with status="done".
    def handle_run_status(req, run_id)
      return unauthorized unless authenticated?(req)
      return [404, { "error" => "run_id not found" }] unless run_id =~ RUN_ID_PATTERN

      snapshot = @runs_mutex.synchronize do
        record = @runs[run_id]
        next nil unless record
        {
          status:       record[:status],
          submitted_at: record[:submitted_at],
          started_at:   record[:started_at],
          finished_at:  record[:finished_at],
          result:       record[:result],
          error:        record[:error]
        }
      end
      return [404, { "error" => "run_id not found" }] unless snapshot

      body = { "run_id" => run_id, "status" => snapshot[:status] }
      case snapshot[:status]
      when "queued"
        body["submitted_at"] = snapshot[:submitted_at].iso8601
      when "running"
        body["started_at"] = snapshot[:started_at].iso8601
        body["elapsed_ms"] = ((Time.now - snapshot[:started_at]) * 1000).to_i
      when "done"
        r = snapshot[:result]
        body.merge!(
          "exit_code"   => r.exit_code,
          "error_kind"  => r.error_kind,
          "duration_ms" => r.duration_ms,
          "artifacts"   => r.artifacts.map(&:to_h),
          "log_path"    => r.log_path,
          "warnings"    => r.warnings,
          "finished_at" => snapshot[:finished_at].iso8601
        )
      when "error"
        body["error"]       = snapshot[:error]
        body["finished_at"] = snapshot[:finished_at].iso8601
      when "cancelled"
        body["finished_at"] = snapshot[:finished_at].iso8601
      end

      [200, body]
    end

    # POST /invoke — accept a run for asynchronous execution.
    #
    # Validation is synchronous (charset/containment/export errors still come
    # back as 4xx on the POST itself). A well-formed request is registered,
    # enqueued for the worker, and answered with 202 + {run_id}. The caller
    # polls GET /runs/:id for progress and the eventual result. A client that
    # disconnects after the 202 does NOT cancel the run — use POST /cancel/:id.
    def handle_invoke(req)
      return [503, { "error" => "server shutting down" }] if @shutting_down
      return unauthorized unless authenticated?(req)

      body = parse_json_body(req)
      return [400, { "error" => "invalid or missing JSON body" }] if body.nil?

      begin
        request = InvokeRequest.from_hash(body, workflows_dir: @runner.workflows_dir, secrets_dir: @runner.secrets_dir)
      rescue InvokeError => e
        return [e.status_code, { "error" => e.message }]
      end

      # Bound the accepted-but-unfinished backlog. Without this a token holder
      # could fire thousands of /invoke calls and pin unbounded memory (each
      # queued record holds the request, including inline credentials).
      if current_in_flight_count >= @max_queued_runs
        return [503, { "error" => "run queue full; retry later", "retry_after" => 5 }]
      end

      submitted_at = Time.now
      registered = @in_flight_mutex.synchronize do
        next false if @in_flight.key?(request.run_id)
        @in_flight[request.run_id] = {
          run_id:       request.run_id,
          profile_key:  request.profile_key,
          submitted_at: submitted_at,
          # nil until the worker dequeues and spawns; /status reads its presence
          # to tell "queued" from "running" and to split queue-wait from run-time.
          started_at:   nil,
          pid:          nil,
          pgid:         nil
        }
        true
      end
      return [409, { "error" => "run_id already in flight" }] unless registered

      @runs_mutex.synchronize do
        # Reusing a run_id whose prior record is still retained: drop the stale
        # terminal record so the fresh run reports its own state.
        forget_run(request.run_id)
        @runs[request.run_id] = {
          run_id:       request.run_id,
          profile_key:  request.profile_key,
          status:       "queued",
          request:      request,
          submitted_at: submitted_at,
          started_at:   nil,
          finished_at:  nil,
          result:       nil,
          error:        nil
        }
      end
      @run_queue << request.run_id

      [202, {
        "run_id" => request.run_id,
        "status" => "queued"
      }]
    end

    # Single worker: pops accepted run_ids and executes them one at a time.
    # Serialization via @invoke_mutex is preserved end-to-end (prune still
    # queues behind a live invoke on the same mutex).
    def run_worker
      loop do
        run_id = @run_queue.pop
        break if run_id.equal?(WORKER_SHUTDOWN)
        begin
          execute_run(run_id)
        rescue StandardError => e
          log_exception("worker", e)
          finalize_run(run_id, nil, InvokeError.new(:server_error, "#{e.class}: #{e.message}"))
        end
      end
    end

    def execute_run(run_id)
      record  = @runs_mutex.synchronize { @runs[run_id] }
      return unless record                      # forgotten (reuse) before dequeue
      return unless record[:status] == "queued" # already cancelled while queued

      # Don't start a fresh bank login during shutdown; abort the queued run.
      if @shutting_down
        finalize_run(run_id, nil, InvokeError.new(:unavailable, "server shutting down"))
        return
      end

      request = record[:request]
      started_at = Time.now
      @runs_mutex.synchronize do
        # Re-check under the lock: a cancel could have landed between the read
        # above and here.
        return unless record[:status] == "queued"
        record[:status]     = "running"
        record[:started_at] = started_at
      end
      # Mirror the start into the in-flight entry so /status can flip this run
      # from queued → running and stop its queued_ms from climbing.
      @in_flight_mutex.synchronize do
        entry = @in_flight[run_id]
        entry[:started_at] = started_at if entry
      end

      result = nil
      error  = nil
      @invoke_mutex.synchronize do
        begin
          result = @runner.run(request) do |pid, pgid|
            @in_flight_mutex.synchronize do
              entry = @in_flight[run_id]
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
          @in_flight_mutex.synchronize { @in_flight.delete(run_id) }
        end
      end

      finalize_run(run_id, result, error)
    end

    # Move a run to a terminal state and record its outcome. Drops the request
    # reference (which may hold inline credentials) so nothing sensitive lingers
    # in a retained record, then evicts the oldest terminal records past the cap.
    def finalize_run(run_id, result, error)
      @runs_mutex.synchronize do
        record = @runs[run_id]
        return unless record
        return if terminal_status?(record[:status]) # cancel already finalized it

        record[:request]     = nil
        record[:finished_at] = Time.now
        if error
          record[:status] = "error"
          record[:error]  = error.message
        else
          record[:status] = "done"
          record[:result] = result
        end

        retain_terminal(run_id)
      end
    end

    # Append a just-finished run to the eviction index and drop the oldest
    # terminal records past the retention cap. Caller must hold @runs_mutex.
    def retain_terminal(run_id)
      record_run_metrics(@runs[run_id])
      @completed_order << run_id
      while @completed_order.size > @max_retained_runs
        oldest = @completed_order.shift
        @runs.delete(oldest)
      end
    end

    # Fold one just-finished run into the cumulative /metrics counters. Called
    # from retain_terminal — the single point every terminal run passes through
    # (done/error via finalize_run, cancelled via handle_cancel) — so each run
    # is counted exactly once. Caller holds @runs_mutex; @metrics_mutex nests
    # under it (never the reverse), so no lock-order cycle.
    def record_run_metrics(record)
      return unless record
      status = record[:status]
      result = record[:result]
      duration_ms =
        if result
          result.duration_ms.to_i
        elsif record[:finished_at]
          base = record[:started_at] || record[:submitted_at]
          base ? ((record[:finished_at] - base) * 1000).to_i : 0
        else
          0
        end
      # error_kind: the runner's classification for a completed child ("ok" when
      # it exited clean), else the server-side terminal status (error/cancelled).
      kind = result&.error_kind || (status == "done" ? "ok" : status)
      @metrics_mutex.synchronize do
        @metrics[:runs_total]        += 1
        @metrics[:duration_ms_total] += duration_ms
        @metrics[:by_status][status] += 1
        @metrics[:by_error_kind][kind] += 1
      end
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
      200
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
      return status if length.zero?

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
      status
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
      416
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
        # Drop already-expired cards so dead prompts don't linger in client
        # UIs (the runner's own deadline has already given up on them).
        next if prompt_expired?(payload["expires_at"])
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

      # Refuse to write a response for a run that is no longer in flight. If the
      # child crashed after emitting a prompt request, nothing will ever consume
      # the response — writing an OTP-bearing response.json here would strand a
      # secret on the host-bind-mounted runs dir until external retention reaps
      # it. No live child means no legitimate reason to answer.
      unless in_flight?(run_id)
        return [409, { "error" => "run is not in flight; prompt can no longer be answered" }]
      end

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
      return [404, { "error" => "run_id not in flight or not yet spawned" }] unless entry

      # Cancel-while-queued: atomically flip the record to "cancelled" iff it
      # hasn't started. The worker re-checks status=="queued" under @runs_mutex
      # before spawning, so whichever side wins this lock is authoritative — no
      # child is ever spawned for a run cancelled here.
      cancelled_while_queued = @runs_mutex.synchronize do
        record = @runs[run_id]
        if record && record[:status] == "queued"
          record[:status]      = "cancelled"
          record[:request]     = nil
          record[:finished_at] = Time.now
          retain_terminal(run_id)
          true
        else
          false
        end
      end
      if cancelled_while_queued
        @in_flight_mutex.synchronize { @in_flight.delete(run_id) }
        return [202, { "accepted" => true, "run_id" => run_id }]
      end

      # Running (or in the brief pre-spawn window). Re-read the pgid: it may have
      # been registered between the snapshot above and now.
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
      return true if @invoke_tokens.empty?
      header = req.headers["authorization"].to_s
      return false unless header.start_with?("Bearer ")
      provided = header.sub(/\ABearer\s+/, "").strip
      # Compare against every configured token and OR the results without
      # short-circuiting, so acceptance time doesn't depend on which token
      # matched (or how many precede it in the list).
      matched = false
      @invoke_tokens.each { |token| matched |= secure_compare(provided, token) }
      matched
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

    def in_flight?(run_id)
      @in_flight_mutex.synchronize { @in_flight.key?(run_id) }
    end

    TERMINAL_STATUSES = %w[done error cancelled].freeze

    def terminal_status?(status)
      TERMINAL_STATUSES.include?(status)
    end

    # Drop a run record entirely (used when a run_id is reused). Caller must
    # hold @runs_mutex.
    def forget_run(run_id)
      return unless @runs.key?(run_id)
      @runs.delete(run_id)
      @completed_order.delete(run_id)
    end

    # Mark every still-queued run as errored. Called during shutdown drain, after
    # the worker has been asked to stop, so no run flips out from under us.
    def abort_pending_runs(message)
      to_abort = @runs_mutex.synchronize do
        @runs.each_value.select { |r| r[:status] == "queued" }.map { |r| r[:run_id] }
      end
      to_abort.each do |run_id|
        @in_flight_mutex.synchronize { @in_flight.delete(run_id) }
        finalize_run(run_id, nil, InvokeError.new(:unavailable, message))
      end
    end

    # True when expires_at is a parseable ISO8601 timestamp in the past. A
    # missing or malformed timestamp is treated as not-expired so we never
    # hide a live prompt on a stale-on-disk field.
    def prompt_expired?(expires_at)
      return false unless expires_at
      Time.iso8601(expires_at) < Time.now
    rescue ArgumentError
      false
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
