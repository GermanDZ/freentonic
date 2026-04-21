# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "net/http"
require "socket"
require "json"
require "freentonic/invoke_server"
require "freentonic/invoke_runner"

# End-to-end tests for the HTTP layer. Spins up InvokeServer in a thread
# on a random port, hits it over real TCP with Net::HTTP, and tears down.
#
# Focus is on /runs/:run_id/log (#3 feature) plus the basics of /healthz
# and auth. Full /invoke coverage is in invoke_runner_test.rb.
class InvokeServerTest < Minitest::Test
  FakeRunner = Struct.new(:runs_dir, :workflows_dir)

  def setup
    @runs_dir      = Dir.mktmpdir("freentonic-server-test-runs-")
    @workflows_dir = Dir.mktmpdir("freentonic-server-test-workflows-")
    @runner        = FakeRunner.new(@runs_dir, @workflows_dir)
    @port          = find_free_port
    @token         = "test-token-#{rand(1_000_000)}"

    @server = Freentonic::InvokeServer.new(
      runner:       @runner,
      invoke_token: @token,
      listen_addr:  "127.0.0.1",
      listen_port:  @port,
      logger:       nil
    )
    @thread = Thread.new { @server.start }
    wait_for_server_up
  end

  def teardown
    @server.shutdown
    @thread.join(3)
    FileUtils.rm_rf(@runs_dir)
    FileUtils.rm_rf(@workflows_dir)
  end

  # ── helpers ───────────────────────────────────────────────

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

  def get(path, headers = {})
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    req = Net::HTTP::Get.new(uri.request_uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end

  def auth(extra = {})
    { "Authorization" => "Bearer #{@token}" }.merge(extra)
  end

  def write_log(run_id, contents)
    dir = File.join(@runs_dir, run_id)
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "log"), contents)
  end

  # ── /healthz (sanity) ─────────────────────────────────────

  def test_healthz_is_open
    res = get("/healthz")
    assert_equal "200", res.code
    assert_equal true, JSON.parse(res.body)["ok"]
  end

  # ── /runs/:run_id/log auth + validation ───────────────────

  def test_log_requires_auth
    write_log("run-a", "hello")
    res = get("/runs/run-a/log")
    assert_equal "401", res.code
  end

  def test_log_rejects_wrong_token
    write_log("run-a", "hello")
    res = get("/runs/run-a/log", { "Authorization" => "Bearer wrong" })
    assert_equal "401", res.code
  end

  def test_log_404_when_run_dir_missing
    res = get("/runs/never-existed/log", auth)
    assert_equal "404", res.code
  end

  def test_log_404_when_run_id_charset_invalid
    # '$' is outside the RUN_ID_PATTERN charset; before we even touch FS.
    res = get("/runs/bad$id/log", auth)
    assert_equal "404", res.code
  end

  def test_log_405_on_non_get
    write_log("run-a", "x")
    uri = URI("http://127.0.0.1:#{@port}/runs/run-a/log")
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Authorization"] = "Bearer #{@token}"
    req.body = ""
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    assert_equal "405", res.code
  end

  # ── /runs/:run_id/log full download ───────────────────────

  def test_log_serves_full_contents
    write_log("run-a", "line1\nline2\n")
    res = get("/runs/run-a/log", auth)
    assert_equal "200", res.code
    assert_equal "line1\nline2\n", res.body
    assert_equal "12", res["Content-Length"]
    assert_equal "bytes", res["Accept-Ranges"]
    assert_equal "text/plain; charset=utf-8", res["Content-Type"]
  end

  def test_log_serves_empty_file
    write_log("run-a", "")
    res = get("/runs/run-a/log", auth)
    assert_equal "200", res.code
    assert_equal "", res.body
    assert_equal "0", res["Content-Length"]
  end

  # ── /runs/:run_id/log Range requests ──────────────────────

  def test_log_206_for_open_ended_range
    write_log("run-a", "0123456789")
    res = get("/runs/run-a/log", auth("Range" => "bytes=5-"))
    assert_equal "206", res.code
    assert_equal "56789", res.body
    assert_equal "bytes 5-9/10", res["Content-Range"]
    assert_equal "5", res["Content-Length"]
  end

  def test_log_206_for_closed_range
    write_log("run-a", "0123456789")
    res = get("/runs/run-a/log", auth("Range" => "bytes=2-4"))
    assert_equal "206", res.code
    assert_equal "234", res.body
    assert_equal "bytes 2-4/10", res["Content-Range"]
  end

  def test_log_206_for_suffix_range
    write_log("run-a", "0123456789")
    res = get("/runs/run-a/log", auth("Range" => "bytes=-3"))
    assert_equal "206", res.code
    assert_equal "789", res.body
    assert_equal "bytes 7-9/10", res["Content-Range"]
  end

  def test_log_206_clamps_last_to_file_end
    write_log("run-a", "0123456789")
    res = get("/runs/run-a/log", auth("Range" => "bytes=7-100"))
    assert_equal "206", res.code
    assert_equal "789", res.body
    assert_equal "bytes 7-9/10", res["Content-Range"]
  end

  def test_log_416_when_start_past_end
    write_log("run-a", "0123456789")
    res = get("/runs/run-a/log", auth("Range" => "bytes=100-"))
    assert_equal "416", res.code
    assert_equal "bytes */10", res["Content-Range"]
  end

  def test_log_400_for_malformed_range
    write_log("run-a", "0123456789")
    res = get("/runs/run-a/log", auth("Range" => "kilobytes=5-"))
    assert_equal "400", res.code
  end

  def test_log_polling_workflow_sees_appended_bytes
    # Simulates a client that reads once, then asks for "bytes=N-" where
    # N is where it left off. The feature exists so the Rails UI can live-tail.
    write_log("run-a", "first chunk\n")
    r1 = get("/runs/run-a/log", auth)
    assert_equal "200", r1.code
    assert_equal "first chunk\n", r1.body

    # Simulate the runner appending more output.
    File.open(File.join(@runs_dir, "run-a", "log"), "ab") { |f| f.write("second chunk\n") }

    r2 = get("/runs/run-a/log", auth("Range" => "bytes=#{r1.body.bytesize}-"))
    assert_equal "206", r2.code
    assert_equal "second chunk\n", r2.body
    assert_equal "bytes 12-24/25", r2["Content-Range"]
  end

  # ── unknown routes ────────────────────────────────────────

  def test_unknown_path_is_404
    res = get("/does/not/exist", auth)
    assert_equal "404", res.code
  end

  def test_runs_path_without_log_suffix_is_404
    write_log("run-a", "hi")
    res = get("/runs/run-a", auth)
    assert_equal "404", res.code
  end
end
