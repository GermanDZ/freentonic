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
  FakeRunner = Struct.new(:runs_dir, :workflows_dir, :chrome_profile_root)

  def setup
    @runs_dir            = Dir.mktmpdir("freentonic-server-test-runs-")
    @workflows_dir       = Dir.mktmpdir("freentonic-server-test-workflows-")
    @chrome_profile_root = Dir.mktmpdir("freentonic-server-test-chrome-")
    @runner              = FakeRunner.new(@runs_dir, @workflows_dir, @chrome_profile_root)
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
    FileUtils.rm_rf(@chrome_profile_root)
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

  def post(path, body, headers = {})
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    req.body = body.is_a?(String) ? body : JSON.generate(body)
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

  # Direct raw-socket access lets us craft requests the high-level HTTP
  # client would mangle or refuse (oversized headers, odd Content-Length,
  # Transfer-Encoding, etc.).
  def raw_request(payload)
    sock = TCPSocket.new("127.0.0.1", @port)
    sock.write(payload)
    response = +""
    while (chunk = sock.read(4096))
      response << chunk
    end
    sock.close
    response
  end

  def parse_status(raw_response)
    raw_response.lines.first.to_s.split(" ", 3)[1]
  end

  def test_bogus_content_length_rejected
    raw = raw_request(
      "POST /invoke HTTP/1.1\r\n" \
      "Host: x\r\n" \
      "Authorization: Bearer #{@token}\r\n" \
      "Content-Type: application/json\r\n" \
      "Content-Length: abc\r\n" \
      "\r\n"
    )
    assert_equal "400", parse_status(raw)
    assert_match(/invalid Content-Length/, raw)
  end

  def test_negative_content_length_rejected
    raw = raw_request(
      "POST /invoke HTTP/1.1\r\n" \
      "Host: x\r\n" \
      "Authorization: Bearer #{@token}\r\n" \
      "Content-Length: -5\r\n" \
      "\r\n"
    )
    assert_equal "400", parse_status(raw)
    assert_match(/invalid Content-Length/, raw)
  end

  def test_transfer_encoding_chunked_rejected
    # We don't support chunked. Silently falling back to Content-Length would
    # be a request-smuggling shape if a fronting proxy disagreed about framing.
    raw = raw_request(
      "POST /invoke HTTP/1.1\r\n" \
      "Host: x\r\n" \
      "Authorization: Bearer #{@token}\r\n" \
      "Transfer-Encoding: chunked\r\n" \
      "\r\n" \
      "0\r\n\r\n"
    )
    assert_equal "400", parse_status(raw)
    assert_match(/Transfer-Encoding not supported/, raw)
  end

  def test_over_capacity_returns_503
    # Spin up a second server with a cap of 1 to make the assertion
    # deterministic. Hold one slow connection open (sends no data, server's
    # readline blocks in IO.select) and verify a second connection is
    # refused immediately with 503 Service Unavailable.
    capped_port = find_free_port
    capped_server = Freentonic::InvokeServer.new(
      runner:                     @runner,
      invoke_token:               @token,
      listen_addr:                "127.0.0.1",
      listen_port:                capped_port,
      logger:                     nil,
      max_concurrent_connections: 1
    )
    thread = Thread.new { capped_server.start }
    # Wait for the server to be up AND to have fully processed one request.
    # A "TCPSocket.new; close" probe returns before the server has necessarily
    # accepted the connection, so any counter bump could still be pending when
    # we start the real test scenario below. Completing a GET /healthz
    # request/response proves the server did a full accept-handle-release
    # cycle before we proceed.
    deadline = Time.now + 5
    loop do
      raise "capped server never came up" if Time.now > deadline
      begin
        sock = TCPSocket.new("127.0.0.1", capped_port)
        sock.write("GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
        IO.select([sock], nil, nil, 2)
        sock.read(256)
        sock.close
        break
      rescue
        sleep 0.02
      end
    end

    # Drain any residual counter bump so our next assertion on the counter
    # only sees `slow`'s bump.
    drain_deadline = Time.now + 2
    while capped_server.active_connection_count > 0
      raise "server never drained probe connection(s)" if Time.now > drain_deadline
      sleep 0.01
    end

    slow = TCPSocket.new("127.0.0.1", capped_port)
    begin
      # Wait deterministically for the server's accept loop to have
      # processed `slow` and bumped the counter; otherwise a fast test
      # can race past this point with `second` getting accepted before
      # the counter goes to 1.
      slow_deadline = Time.now + 2
      until capped_server.active_connection_count >= 1
        raise "server never accepted the slow connection" if Time.now > slow_deadline
        sleep 0.01
      end

      second = TCPSocket.new("127.0.0.1", capped_port)
      second.write("GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
      response = +""
      begin
        while (chunk = second.read(4096))
          response << chunk
        end
      rescue Errno::ECONNRESET
        # Refusing close can RST in some kernels; we already have the
        # 503 bytes from before the RST.
      end
      second.close
      assert_equal "503", parse_status(response)
      assert_match(/Retry-After: 1/, response)
    ensure
      slow.close rescue nil
      capped_server.shutdown
      thread.join(3)
    end
  end

  def test_oversized_header_rejected_even_on_final_line
    # Single header that individually exceeds the 16 KiB cap. Prior to the
    # check-after-read fix, an oversized *final* header could bypass the cap.
    giant = "X-Huge: " + ("a" * 20_000) + "\r\n"
    raw = raw_request(
      "GET /healthz HTTP/1.1\r\n" \
      "Host: x\r\n" \
      "#{giant}" \
      "\r\n"
    )
    assert_equal "400", parse_status(raw)
    assert_match(/headers too large/, raw)
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

  # ── POST /profiles/prune ──────────────────────────────────

  def make_profile(key, file_name: "Cookies", file_bytes: "cookies-blob")
    dir = File.join(@chrome_profile_root, key)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, file_name), file_bytes)
    dir
  end

  def profile_exists?(key)
    Dir.exist?(File.join(@chrome_profile_root, key))
  end

  def test_prune_requires_auth
    res = post("/profiles/prune", { "profile_key" => "x" })
    assert_equal "401", res.code
  end

  def test_prune_rejects_both_profile_key_and_prefix
    res = post("/profiles/prune", { "profile_key" => "a", "prefix" => "b" }, auth)
    assert_equal "400", res.code
  end

  def test_prune_rejects_neither_profile_key_nor_prefix
    res = post("/profiles/prune", {}, auth)
    assert_equal "400", res.code
  end

  def test_prune_rejects_invalid_body
    res = post("/profiles/prune", "{not json", auth)
    assert_equal "400", res.code
  end

  def test_prune_rejects_profile_key_charset
    res = post("/profiles/prune", { "profile_key" => "bad/key" }, auth)
    assert_equal "400", res.code
  end

  def test_prune_rejects_traversal_in_profile_key
    res = post("/profiles/prune", { "profile_key" => "../etc" }, auth)
    # Either charset (slash) or realpath guard catches it; both acceptable.
    assert_equal "400", res.code
  end

  def test_prune_exact_profile_deletes_dir
    make_profile("ing__owner42")
    assert profile_exists?("ing__owner42")

    res = post("/profiles/prune", { "profile_key" => "ing__owner42" }, auth)
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal 1, body["count"]
    assert_equal ["ing__owner42"], body["deleted"]
    refute profile_exists?("ing__owner42"), "profile dir should be gone"
  end

  def test_prune_exact_profile_missing_is_idempotent
    res = post("/profiles/prune", { "profile_key" => "never-existed" }, auth)
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal 0, body["count"]
    assert_equal [], body["deleted"]
  end

  def test_prune_by_prefix_deletes_matching
    make_profile("ing__owner42")
    make_profile("ing__owner99")
    make_profile("revolut__owner42")

    res = post("/profiles/prune", { "prefix" => "ing__" }, auth)
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal 2, body["count"]
    assert_equal %w[ing__owner42 ing__owner99], body["deleted"].sort
    refute profile_exists?("ing__owner42")
    refute profile_exists?("ing__owner99")
    assert profile_exists?("revolut__owner42"), "non-matching profile must survive"
  end

  def test_prune_by_prefix_no_matches
    make_profile("revolut__owner42")
    res = post("/profiles/prune", { "prefix" => "ing__" }, auth)
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal 0, body["count"]
    assert profile_exists?("revolut__owner42")
  end

  def test_prune_by_empty_prefix_is_rejected
    res = post("/profiles/prune", { "prefix" => "" }, auth)
    assert_equal "400", res.code
  end

  def test_prune_by_prefix_charset_rejected
    res = post("/profiles/prune", { "prefix" => "bad/prefix" }, auth)
    assert_equal "400", res.code
  end

  def test_prune_skips_symlink_escaping_root
    # Create a symlink inside the profile root pointing at /tmp/<something>.
    # A charset-matching prefix should still NOT delete the symlink target.
    outside = Dir.mktmpdir("freentonic-outside-")
    link_name = "ing__symlink"
    File.symlink(outside, File.join(@chrome_profile_root, link_name))

    res = post("/profiles/prune", { "prefix" => "ing__" }, auth)
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    refute_includes body["deleted"], link_name, "symlink must not appear in deleted list"
    assert Dir.exist?(outside), "symlink target outside the profile root must survive"
  ensure
    FileUtils.rm_rf(outside) if outside
    File.unlink(File.join(@chrome_profile_root, link_name)) rescue nil
  end

  def test_prune_405_on_get
    res = get("/profiles/prune", auth)
    assert_equal "405", res.code
  end
end
