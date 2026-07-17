# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "net/http"
require "socket"
require "json"
require "freentonic/invoke_server"

# HTTP-layer tests for the held-open step session endpoints (/sessions). The
# supervisor (process + pipe mechanics) is stubbed with an in-memory fake, so
# these exercise the server's routing, auth, one-at-a-time guarantee, JSONL
# proxying, teardown, and idle watchdog WITHOUT launching Chrome (AGENTS.md
# invariant 10). The real StepSessionSupervisor is covered separately.
class InvokeServerSessionsTest < Minitest::Test
  # Minimal runner duck-type: the server reads workflows_dir/secrets_dir off it
  # when building the InvokeRequest.
  FakeRunner = Struct.new(:runs_dir, :workflows_dir, :chrome_profile_root, :secrets_dir)

  # Stands in for StepSessionSupervisor. Records lifecycle, replays canned
  # envelopes, and can be told to fail an open.
  class FakeStepSupervisor
    Handle = Struct.new(:id)
    attr_reader :opened, :closed, :sent
    attr_accessor :open_error

    def initialize
      @opened = []
      @closed = []
      @sent   = []
      @open_error = nil
    end

    def open(request)
      @opened << request.run_id
      yield(4242, 4242) if block_given? # fake pid/pgid → server records session pgid
      raise @open_error if @open_error

      Handle.new(request.run_id)
    end

    def send(handle, message)
      @sent << [handle.id, message]
      if message == "page"
        { "ok" => true, "page" => { "url" => "https://bank.example/x", "title" => "X", "interactive" => [] } }
      else
        action = (JSON.parse(message)["action"] rescue nil)
        { "ok" => true, "action" => action }
      end
    end

    def close(handle)
      @closed << handle.id
    end
  end

  def setup
    @runs_dir            = Dir.mktmpdir("freentonic-sessions-runs-")
    @workflows_dir       = Dir.mktmpdir("freentonic-sessions-workflows-")
    @chrome_profile_root = Dir.mktmpdir("freentonic-sessions-chrome-")
    @secrets_dir         = Dir.mktmpdir("freentonic-sessions-secrets-")
    # InvokeRequest only checks the workflow is a regular file under the root.
    File.write(File.join(@workflows_dir, "dummy.yml"), "version: 1\n")

    @runner       = FakeRunner.new(@runs_dir, @workflows_dir, @chrome_profile_root, @secrets_dir)
    @supervisor   = FakeStepSupervisor.new
    @port         = find_free_port
    @token        = "test-token-#{rand(1_000_000)}"

    @server = Freentonic::InvokeServer.new(
      runner:               @runner,
      invoke_tokens:        [@token],
      listen_addr:          "127.0.0.1",
      listen_port:          @port,
      logger:               nil,
      step_supervisor:      @supervisor,
      session_idle_timeout: idle_timeout
    )
    @thread = Thread.new { @server.start }
    wait_for_server_up
  end

  def teardown
    @server.shutdown
    @thread.join(3)
    [@runs_dir, @workflows_dir, @chrome_profile_root, @secrets_dir].each { |d| FileUtils.rm_rf(d) }
  end

  # Overridable per-test (the idle-watchdog test lowers it).
  def idle_timeout = 300

  # ── helpers ───────────────────────────────────────────────

  def find_free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_for_server_up(timeout: 20)
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

  def request(klass, path, headers: {}, body: nil)
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    req = klass.new(uri.request_uri)
    req["Content-Type"] = "application/json" if body
    req.body = body.is_a?(String) ? body : JSON.generate(body) if body
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end

  def post(path, body, headers = {}) = request(Net::HTTP::Post, path, headers: headers, body: body)
  def get(path, headers = {})        = request(Net::HTTP::Get,  path, headers: headers)
  def delete(path, headers = {})     = request(Net::HTTP::Delete, path, headers: headers)

  def auth(extra = {}) = { "Authorization" => "Bearer #{@token}" }.merge(extra)

  def open_body(run_id: "sess-1")
    { "run_id" => run_id, "workflow" => "dummy.yml", "credentials" => { "inline" => { "USER" => "x" } } }
  end

  def open_session(run_id: "sess-1")
    post("/sessions", open_body(run_id: run_id), auth)
  end

  # ── lifecycle ─────────────────────────────────────────────

  def test_open_step_returns_201_with_session_id
    res = open_session
    assert_equal "201", res.code
    body = JSON.parse(res.body)
    assert_equal "sess-1", body["session_id"]
    assert_equal "open", body["status"]
    assert_equal ["sess-1"], @supervisor.opened
  end

  def test_step_forwards_body_and_returns_child_envelope
    open_session
    res = post("/sessions/sess-1/step", { "action" => "click", "selector" => "#x" }, auth)
    assert_equal "200", res.code
    assert_equal({ "ok" => true, "action" => "click" }, JSON.parse(res.body))
    # The action object was forwarded verbatim to the child.
    id, message = @supervisor.sent.last
    assert_equal "sess-1", id
    assert_equal({ "action" => "click", "selector" => "#x" }, JSON.parse(message))
  end

  def test_page_returns_observation
    open_session
    res = get("/sessions/sess-1/page", auth)
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal true, body["ok"]
    assert_equal "https://bank.example/x", body["page"]["url"]
    assert_equal ["sess-1", "page"], @supervisor.sent.last
  end

  def test_delete_closes_session_and_frees_the_slot
    open_session
    res = delete("/sessions/sess-1", auth)
    assert_equal "200", res.code
    assert_equal "closed", JSON.parse(res.body)["status"]
    assert_equal ["sess-1"], @supervisor.closed
    # Slot freed: a step now 404s, and a fresh open succeeds.
    assert_equal "404", post("/sessions/sess-1/step", { "action" => "reload" }, auth).code
    assert_equal "201", open_session(run_id: "sess-2").code
  end

  # ── one-at-a-time ─────────────────────────────────────────

  def test_second_open_is_rejected_while_one_is_held
    assert_equal "201", open_session(run_id: "sess-1").code
    res = open_session(run_id: "sess-2")
    assert_equal "409", res.code
    assert_includes JSON.parse(res.body)["error"], "already open"
    assert_equal ["sess-1"], @supervisor.opened
  end

  def test_invoke_is_rejected_while_a_session_is_open
    open_session
    # handle_invoke rejects on session_active? before touching the runner.
    res = post("/invoke", { "run_id" => "r1" }, auth)
    assert_equal "409", res.code
    assert_includes JSON.parse(res.body)["error"], "step session is open"
  end

  def test_open_is_rejected_while_an_invoke_is_in_flight
    # Simulate an in-flight invoke by seeding the in-flight table directly.
    table = @server.instance_variable_get(:@in_flight)
    mutex = @server.instance_variable_get(:@in_flight_mutex)
    mutex.synchronize { table["r-busy"] = { run_id: "r-busy", pgid: nil } }
    begin
      res = open_session
      assert_equal "409", res.code
      assert_includes JSON.parse(res.body)["error"], "invoke is in flight"
    ensure
      mutex.synchronize { table.delete("r-busy") }
    end
  end

  # ── auth ──────────────────────────────────────────────────

  def test_open_requires_auth
    assert_equal "401", post("/sessions", open_body, {}).code
  end

  def test_step_requires_auth
    open_session
    assert_equal "401", post("/sessions/sess-1/step", { "action" => "reload" }, {}).code
  end

  def test_page_and_delete_require_auth
    open_session
    assert_equal "401", get("/sessions/sess-1/page", {}).code
    assert_equal "401", delete("/sessions/sess-1", {}).code
  end

  # ── routing / validation ──────────────────────────────────

  def test_step_on_unknown_session_is_404
    assert_equal "404", post("/sessions/nope/step", { "action" => "reload" }, auth).code
  end

  def test_wrong_methods_are_405
    assert_equal "405", get("/sessions", auth).code                      # open is POST
    open_session
    assert_equal "405", post("/sessions/sess-1", { "x" => 1 }, auth).code # bare id is DELETE
  end

  def test_open_with_missing_workflow_is_400
    res = post("/sessions", { "run_id" => "s", "credentials" => { "inline" => { "U" => "x" } } }, auth)
    assert_equal "400", res.code
  end

  def test_open_supervisor_failure_frees_the_slot
    @supervisor.open_error = Freentonic::InvokeError.new(:server_error, "chrome would not launch")
    res = open_session
    assert_equal "500", res.code
    # The reserved slot was released, so a later open can succeed.
    @supervisor.open_error = nil
    assert_equal "201", open_session(run_id: "sess-2").code
  end

  # ── idle watchdog ─────────────────────────────────────────
  # Uses a second, short-idle server (own port/thread/supervisor) so the shared
  # server's fast tests keep the default 300s timeout and can't be reaped
  # mid-request.

  def test_idle_session_is_closed_by_the_watchdog
    supervisor = FakeStepSupervisor.new
    port       = find_free_port
    server = Freentonic::InvokeServer.new(
      runner:               @runner,
      invoke_tokens:        [@token],
      listen_addr:          "127.0.0.1",
      listen_port:          port,
      logger:               nil,
      step_supervisor:      supervisor,
      session_idle_timeout: 1
    )
    thread = Thread.new { server.start }
    begin
      deadline = Time.now + 20
      sleep 0.02 until (TCPSocket.new("127.0.0.1", port).close rescue false) || Time.now > deadline

      uri = URI("http://127.0.0.1:#{port}/sessions")
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Content-Type"]  = "application/json"
      req.body = JSON.generate(open_body(run_id: "idle-1"))
      res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
      assert_equal "201", res.code

      # Idle timeout is 1s; the watchdog ticks every 1s. Give it a generous
      # window under CI scheduling load.
      closed_deadline = Time.now + 10
      until supervisor.closed.include?("idle-1") || Time.now > closed_deadline
        sleep 0.1
      end
      assert_includes supervisor.closed, "idle-1",
                      "watchdog should have closed the idle session"
    ensure
      server.shutdown
      thread.join(3)
    end
  end
end
