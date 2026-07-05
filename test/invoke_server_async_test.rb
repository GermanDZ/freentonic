# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "net/http"
require "socket"
require "json"
require "freentonic/invoke_server"
require "freentonic/invoke_runner"
require "freentonic/invoke_request"

# End-to-end tests for the asynchronous /invoke lifecycle: POST returns 202 and
# enqueues, a single worker runs invokes serially, and GET /runs/:id reports
# queued → running → done/error/cancelled. Drives a programmable fake runner so
# the "running" window can be held open deterministically (no sleeps).
class InvokeServerAsyncTest < Minitest::Test
  # Fake InvokeRunner. run() optionally blocks on a gate so a test can observe
  # the "running" state and prove serialization, then returns a canned Result
  # (or raises) per run_id. Never spawns a real child; on_start is deliberately
  # NOT called, so no bogus pgid is registered for shutdown to signal.
  class ProgrammableRunner
    attr_reader :workflows_dir, :runs_dir, :chrome_profile_root, :secrets_dir
    attr_reader :started_run_ids, :max_concurrent

    def initialize(workflows_dir:, runs_dir:, chrome_profile_root:, secrets_dir:)
      @workflows_dir       = workflows_dir
      @runs_dir            = runs_dir
      @chrome_profile_root = chrome_profile_root
      @secrets_dir         = secrets_dir

      @mutex           = Mutex.new
      @started_run_ids = []
      @started_q       = Thread::Queue.new
      @release_q       = Thread::Queue.new
      @gated           = false
      @behaviors       = {}   # run_id => :ok | :user_exit | :invoke_error | :crash
      @concurrent      = 0
      @max_concurrent  = 0
    end

    # Make every run() block until #release! is called once per run.
    def gate!
      @gated = true
    end

    def release!
      @release_q << :go
    end

    def behavior(run_id, sym)
      @behaviors[run_id] = sym
    end

    # Block until a run actually enters run(); returns its run_id.
    def wait_started(timeout: 3)
      @started_q.pop(timeout: timeout) or raise "no run started within #{timeout}s"
    end

    def run(request, &_on_start)
      @mutex.synchronize do
        @started_run_ids << request.run_id
        @concurrent += 1
        @max_concurrent = [@max_concurrent, @concurrent].max
      end
      @started_q << request.run_id
      @release_q.pop if @gated
      @mutex.synchronize { @concurrent -= 1 }

      case @behaviors[request.run_id]
      when :user_exit    then make_result(request, exit_code: 1, error_kind: "user_error")
      when :invoke_error then raise Freentonic::InvokeError.new(:unprocessable, "bad thing")
      when :crash        then raise "boom"
      else                    make_result(request, exit_code: 0, error_kind: nil)
      end
    end

    private

    def make_result(request, exit_code:, error_kind:)
      Freentonic::InvokeRunner::Result.new(
        run_id:             request.run_id,
        exit_code:          exit_code,
        error_kind:         error_kind,
        duration_ms:        7,
        artifacts:          [],
        log_path:           "runs/#{request.run_id}/log",
        warnings:           [],
        chrome_profile_dir: File.join(@chrome_profile_root, request.profile_key)
      )
    end
  end

  def setup
    @runs_dir            = Dir.mktmpdir("freentonic-async-runs-")
    @workflows_dir       = Dir.mktmpdir("freentonic-async-workflows-")
    @chrome_profile_root = Dir.mktmpdir("freentonic-async-chrome-")
    @secrets_dir         = Dir.mktmpdir("freentonic-async-secrets-")
    # InvokeRequest validates that the workflow file exists under the root.
    FileUtils.mkdir_p(File.join(@workflows_dir, "acme"))
    File.write(File.join(@workflows_dir, "acme", "workflow.yml"), "steps: []\n")

    @runner = ProgrammableRunner.new(
      workflows_dir:       @workflows_dir,
      runs_dir:            @runs_dir,
      chrome_profile_root: @chrome_profile_root,
      secrets_dir:         @secrets_dir
    )
    @token = "test-token-#{rand(1_000_000)}"
    @port  = find_free_port
  end

  def teardown
    if @server
      @server.shutdown
      # Release any gated run so the worker can drain and the thread exits.
      10.times { @runner.release! }
      @thread&.join(3)
    end
    [@runs_dir, @workflows_dir, @chrome_profile_root, @secrets_dir].each { |d| FileUtils.rm_rf(d) }
  end

  # ── harness ───────────────────────────────────────────────

  # Thread-safe line capture standing in for the server's $stdout logger, so
  # the access-log tests can read back what was logged without racing threads.
  class LogCapture
    def initialize
      @mutex = Mutex.new
      @lines = []
    end

    def puts(msg)
      @mutex.synchronize { @lines.concat(msg.to_s.split("\n")) }
    end

    def flush; end

    def lines
      @mutex.synchronize { @lines.dup }
    end
  end

  def boot(max_queued_runs: 128, max_retained_runs: 256, logger: nil)
    @server = Freentonic::InvokeServer.new(
      runner:            @runner,
      invoke_tokens:     [@token],
      listen_addr:       "127.0.0.1",
      listen_port:       @port,
      logger:            logger,
      max_queued_runs:   max_queued_runs,
      max_retained_runs: max_retained_runs
    )
    @thread = Thread.new { @server.start }
    wait_for_server_up
  end

  def find_free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_for_server_up(timeout: 5)
    deadline = Time.now + timeout
    while Time.now < deadline
      begin
        TCPSocket.new("127.0.0.1", @port).close
        return
      rescue StandardError
        sleep 0.02
      end
    end
    raise "server did not start listening on port #{@port}"
  end

  def auth(extra = {})
    { "Authorization" => "Bearer #{@token}" }.merge(extra)
  end

  def get(path, headers = {})
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    req = Net::HTTP::Get.new(uri.request_uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end

  def post(path, body, headers = {})
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    req.body = body.is_a?(String) ? body : JSON.generate(body)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end

  def invoke_body(run_id, profile_key: "acme__t1")
    {
      run_id:      run_id,
      workflow:    "acme/workflow.yml",
      profile_key: profile_key,
      credentials: { inline: { "USER" => "u", "PIN" => "1234" } }
    }
  end

  def submit(run_id, **opts)
    post("/invoke", invoke_body(run_id, **opts), auth)
  end

  def run_status(run_id)
    res = get("/runs/#{run_id}", auth)
    [res.code, (JSON.parse(res.body) if res["Content-Type"]&.include?("json"))]
  end

  # Poll GET /runs/:id until it reaches a terminal status or times out.
  def wait_for_status(run_id, want, timeout: 3)
    deadline = Time.now + timeout
    loop do
      _, body = run_status(run_id)
      return body if body && body["status"] == want
      raise "timed out waiting for #{run_id} → #{want} (last=#{body.inspect})" if Time.now > deadline
      sleep 0.01
    end
  end

  # ── happy path ────────────────────────────────────────────

  def test_invoke_returns_202_with_run_id_and_status_queued
    boot
    res = submit("run-1")
    assert_equal "202", res.code
    body = JSON.parse(res.body)
    assert_equal "run-1", body["run_id"]
    assert_equal "queued", body["status"]
  end

  def test_run_reaches_done_with_result_fields
    boot
    submit("run-ok")
    body = wait_for_status("run-ok", "done")
    assert_equal 0, body["exit_code"]
    assert_nil body["error_kind"]
    assert_equal "runs/run-ok/log", body["log_path"]
    assert_equal [], body["artifacts"]
    assert_equal [], body["warnings"]
    assert body["finished_at"]
  end

  def test_nonzero_exit_is_done_not_error
    boot
    @runner.behavior("run-ue", :user_exit)
    submit("run-ue")
    body = wait_for_status("run-ue", "done")
    assert_equal 1, body["exit_code"]
    assert_equal "user_error", body["error_kind"]
  end

  def test_invoke_error_during_run_becomes_error_status
    boot
    @runner.behavior("run-ie", :invoke_error)
    submit("run-ie")
    body = wait_for_status("run-ie", "error")
    assert_match(/bad thing/, body["error"])
    assert body["finished_at"]
  end

  def test_unexpected_crash_during_run_becomes_error_status
    boot
    @runner.behavior("run-crash", :crash)
    submit("run-crash")
    body = wait_for_status("run-crash", "error")
    assert_match(/RuntimeError|boom/, body["error"])
  end

  # ── state visibility while in flight ──────────────────────

  def test_running_and_queued_states_visible
    boot
    @runner.gate!
    submit("run-A")
    @runner.wait_started               # A is now inside run(), blocked
    submit("run-B")                    # B is queued behind A

    _, a = run_status("run-A")
    assert_equal "running", a["status"]
    assert a["started_at"]
    assert a["elapsed_ms"] >= 0

    _, b = run_status("run-B")
    assert_equal "queued", b["status"]
    assert b["submitted_at"]

    @runner.release!                   # let A finish
    wait_for_status("run-A", "done")
    @runner.release!                   # let B finish
    wait_for_status("run-B", "done")
  end

  def test_runs_execute_serially_fifo
    boot
    @runner.gate!
    submit("s-1")
    @runner.wait_started
    submit("s-2")
    submit("s-3")
    # Drain all three, releasing one at a time.
    @runner.release!; wait_for_status("s-1", "done")
    @runner.wait_started
    @runner.release!; wait_for_status("s-2", "done")
    @runner.wait_started
    @runner.release!; wait_for_status("s-3", "done")

    assert_equal 1, @runner.max_concurrent, "invokes must not overlap"
    assert_equal %w[s-1 s-2 s-3], @runner.started_run_ids
  end

  # ── validation stays synchronous on the POST ──────────────

  def test_validation_error_is_returned_on_the_post_not_202
    boot
    res = post("/invoke", { run_id: "bad", workflow: "acme/workflow.yml",
                            credentials: { inline: {} } }, auth) # empty inline
    assert_equal "422", res.code
  end

  def test_invoke_requires_auth
    boot
    res = post("/invoke", invoke_body("noauth"), {})
    assert_equal "401", res.code
  end

  def test_duplicate_run_id_while_in_flight_returns_409
    boot
    @runner.gate!
    submit("dup")
    @runner.wait_started
    res = submit("dup")
    assert_equal "409", res.code
    @runner.release!
    wait_for_status("dup", "done")
  end

  def test_run_id_reusable_after_completion
    boot
    submit("reuse")
    wait_for_status("reuse", "done")
    res = submit("reuse")
    assert_equal "202", res.code
    wait_for_status("reuse", "done")
  end

  # ── GET /runs/:id auth + not-found ────────────────────────

  def test_run_status_requires_auth
    boot
    res = get("/runs/whatever", {})
    assert_equal "401", res.code
  end

  def test_run_status_404_for_unknown_run
    boot
    res = get("/runs/never-submitted", auth)
    assert_equal "404", res.code
  end

  def test_run_status_404_for_invalid_charset
    boot
    res = get("/runs/#{URI.encode_www_form_component('..')}", auth)
    assert_equal "404", res.code
  end

  def test_run_status_405_on_post
    boot
    res = post("/runs/run-x", {}, auth)
    assert_equal "405", res.code
  end

  # ── queue backpressure ────────────────────────────────────

  def test_queue_full_returns_503
    boot(max_queued_runs: 2)
    @runner.gate!
    assert_equal "202", submit("q-1").code   # starts running (in flight)
    @runner.wait_started
    assert_equal "202", submit("q-2").code   # queued (in flight)
    res = submit("q-3")                       # would exceed the cap of 2
    assert_equal "503", res.code
    assert_match(/queue full/, JSON.parse(res.body)["error"])

    @runner.release!; wait_for_status("q-1", "done")
    @runner.wait_started
    @runner.release!; wait_for_status("q-2", "done")
  end

  # ── retention / eviction ──────────────────────────────────

  def test_oldest_completed_runs_are_evicted
    boot(max_retained_runs: 3)
    %w[e-1 e-2 e-3 e-4].each do |id|
      submit(id)
      wait_for_status(id, "done")
    end
    # e-1 fell off the back of the 3-slot retention window.
    assert_equal "404", get("/runs/e-1", auth).code
    assert_equal "200", get("/runs/e-4", auth).code
    assert_equal "200", get("/runs/e-2", auth).code
  end

  # ── cancel while queued ───────────────────────────────────

  def test_cancel_queued_run_never_executes_it
    boot
    @runner.gate!
    submit("c-run")           # occupies the worker
    @runner.wait_started
    submit("c-queued")        # sits in the queue

    res = post("/cancel/c-queued", {}, auth)
    assert_equal "202", res.code

    _, body = run_status("c-queued")
    assert_equal "cancelled", body["status"]
    assert body["finished_at"]

    @runner.release!          # let c-run finish; worker then drains the queue
    wait_for_status("c-run", "done")
    # Give the worker a beat to pop (and skip) the cancelled c-queued.
    sleep 0.1
    refute_includes @runner.started_run_ids, "c-queued",
                    "a queued run cancelled before start must never execute"
  end

  # ── shutdown drains + aborts queued ───────────────────────

  def test_shutdown_aborts_queued_run
    boot
    @runner.gate!
    submit("sd-run")
    @runner.wait_started
    submit("sd-queued")

    # Kick off shutdown from another thread: it closes the socket and the
    # server thread's drain joins the worker (currently blocked in sd-run).
    shutdown_thread = Thread.new { @server.shutdown }
    @runner.release!            # let the running invoke complete
    shutdown_thread.join(3)
    @thread.join(3)

    # The queued run was aborted rather than executed.
    refute_includes @runner.started_run_ids, "sd-queued"
    @server = nil               # teardown already drained
  end

  def test_invoke_refused_while_shutting_down
    boot
    @server.shutdown
    @thread.join(3)
    # A fresh connection may be refused at the socket, but if it lands the
    # handler returns 503. Tolerate either a 503 or a connection error.
    begin
      res = submit("late")
      assert_equal "503", res.code
    rescue StandardError
      # socket already closed — acceptable
    end
    @server = nil
  end

  # ── /status: queued vs running ────────────────────────────

  def json(res)
    JSON.parse(res.body)
  end

  def test_status_distinguishes_queued_from_running
    boot
    @runner.gate!
    submit("st-run")
    @runner.wait_started        # st-run is inside run(), registered as running
    submit("st-queued")         # sits in the queue

    body = json(get("/status", auth))
    by_id = body["in_flight"].each_with_object({}) { |e, h| h[e["run_id"]] = e }

    running = by_id.fetch("st-run")
    assert_equal "running", running["status"]
    assert running["started_at"]
    assert_operator running["elapsed_ms"], :>=, 0
    assert_operator running["queued_ms"], :>=, 0

    queued = by_id.fetch("st-queued")
    assert_equal "queued", queued["status"]
    refute queued.key?("started_at"), "a queued run has not started"
    refute queued.key?("elapsed_ms"), "run-time is meaningless before start"
    assert_operator queued["queued_ms"], :>=, 0

    @runner.release!; wait_for_status("st-run", "done")
    @runner.release!; wait_for_status("st-queued", "done")
  end

  def test_status_requires_auth
    boot
    assert_equal "401", get("/status").code
  end

  # ── /metrics ──────────────────────────────────────────────

  def test_metrics_requires_auth
    boot
    assert_equal "401", get("/metrics").code
  end

  def test_metrics_empty_before_any_run
    boot
    m = json(get("/metrics", auth))
    assert_equal 0, m["runs_total"]
    assert_equal 0, m["duration_ms_avg"]
    assert_equal({}, m["by_status"])
    assert_equal({}, m["by_error_kind"])
  end

  def test_metrics_tally_by_status_and_error_kind
    boot
    # Three runs that complete on their own (not gated), one per outcome.
    @runner.behavior("m-ok",    :ok)
    @runner.behavior("m-user",  :user_exit)
    @runner.behavior("m-crash", :invoke_error)
    submit("m-ok");    wait_for_status("m-ok",    "done")
    submit("m-user");  wait_for_status("m-user",  "done")
    submit("m-crash"); wait_for_status("m-crash", "error")

    # Plus a run cancelled while queued behind a gated one.
    @runner.gate!
    submit("m-block")
    @runner.wait_started
    submit("m-cancel")
    assert_equal "202", post("/cancel/m-cancel", {}, auth).code
    wait_for_status("m-cancel", "cancelled")
    @runner.release!; wait_for_status("m-block", "done")

    m = json(get("/metrics", auth))
    assert_equal 5, m["runs_total"]
    assert_equal 3, m["by_status"]["done"]      # m-ok, m-user, m-block
    assert_equal 1, m["by_status"]["error"]     # m-crash
    assert_equal 1, m["by_status"]["cancelled"] # m-cancel
    assert_equal 2, m["by_error_kind"]["ok"]        # m-ok, m-block exited clean
    assert_equal 1, m["by_error_kind"]["user_error"] # m-user
    assert_equal 1, m["by_error_kind"]["error"]      # m-crash (server-side)
    assert_equal 1, m["by_error_kind"]["cancelled"]  # m-cancel
    assert_operator m["duration_ms_total"], :>=, 0
    assert_kind_of Integer, m["duration_ms_avg"]
  end

  # ── access log ────────────────────────────────────────────

  def test_access_log_one_line_per_request
    log = LogCapture.new
    boot(logger: log)
    get("/healthz")
    submit("al-1"); wait_for_status("al-1", "done")

    lines = log.lines
    assert(lines.any? { |l| l.include?("GET /healthz 200") }, "expected healthz access line, got: #{lines.inspect}")
    assert(lines.any? { |l| l.include?("POST /invoke 202") }, "expected invoke access line")
    # No secret material in access lines: never the bearer token, never a body.
    refute(lines.any? { |l| l.include?(@token) }, "access log must not contain the bearer token")
    # Every access line carries a millisecond timing.
    access = lines.select { |l| l =~ %r{\b(GET|POST) /} }
    assert(access.all? { |l| l =~ /\d+ms\z/ }, "each access line ends with Nms: #{access.inspect}")
  end

  def test_access_log_records_status_of_streaming_log_route
    log = LogCapture.new
    boot(logger: log)
    # No such run → 404 from the streaming log route (which bypasses dispatch).
    assert_equal "404", get("/runs/nope/log", auth).code
    assert(log.lines.any? { |l| l.include?("GET /runs/nope/log 404") },
           "streaming route status must reach the access log: #{log.lines.inspect}")
  end
end
