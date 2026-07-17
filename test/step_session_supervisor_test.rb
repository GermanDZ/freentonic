# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "freentonic/step_session_supervisor"

# Unit tests for the server-side JSONL proxy. A PipeRunner stands in for
# InvokeRunner: its open_step_session returns a handle backed by real
# IO.pipes, and exposes the "child" ends so a test can play the child —
# exercising open/send/close and the read timeouts without a real process.
class StepSessionSupervisorTest < Minitest::Test
  Handle = Struct.new(:stdin, :stdout, :pid, :pgid, :child_in, :child_out)

  class PipeRunner
    attr_reader :closed
    attr_accessor :last_handle, :ready_line

    def initialize(ready_line: %({"ready":true}))
      @closed     = []
      @ready_line = ready_line
    end

    def open_step_session(_request)
      to_child_r,   to_child_w   = IO.pipe # server → child (stdin)
      from_child_r, from_child_w = IO.pipe # child → server (stdout)
      yield(111, 111) if block_given?
      # The child announces readiness the instant it starts.
      if @ready_line
        from_child_w.puts(@ready_line)
        from_child_w.flush
      end
      @last_handle = Handle.new(to_child_w, from_child_r, 111, 111, to_child_r, from_child_w)
    end

    def close_step_session(handle)
      @closed << handle
      handle.stdin.close  rescue nil
      handle.stdout.close rescue nil
      handle.child_in.close  rescue nil
      handle.child_out.close rescue nil
    end
  end

  def supervisor(runner, step_timeout: 5)
    Freentonic::StepSessionSupervisor.new(runner: runner, ready_timeout: 5, step_timeout: step_timeout)
  end

  def teardown
    @runner&.last_handle&.then { |h| @runner.close_step_session(h) }
  end

  def test_open_reads_ready_envelope_and_returns_handle
    @runner = PipeRunner.new
    handle = supervisor(@runner).open(Object.new)
    assert_equal @runner.last_handle, handle
  end

  def test_open_forwards_pid_pgid_to_on_start
    @runner = PipeRunner.new
    seen = nil
    supervisor(@runner).open(Object.new) { |pid, pgid| seen = [pid, pgid] }
    assert_equal [111, 111], seen
  end

  def test_open_without_ready_raises_and_closes_child
    @runner = PipeRunner.new(ready_line: %({"ok":true})) # no ready flag
    err = assert_raises(Freentonic::InvokeError) { supervisor(@runner).open(Object.new) }
    assert_equal 500, err.status_code
    assert_equal 1, @runner.closed.size, "half-open child must be torn down"
  end

  def test_send_writes_a_line_and_reads_one_envelope
    @runner = PipeRunner.new
    sup = supervisor(@runner)
    handle = sup.open(Object.new)
    h = @runner.last_handle

    # Play the child: read the forwarded line, echo an envelope back.
    child = Thread.new do
      line = h.child_in.gets
      h.child_out.puts(JSON.generate("ok" => true, "echo" => JSON.parse(line)))
      h.child_out.flush
    end

    env = sup.send(handle, JSON.generate("action" => "click", "selector" => "#x"))
    child.join(2)

    assert_equal true, env["ok"]
    assert_equal({ "action" => "click", "selector" => "#x" }, env["echo"])
  end

  def test_send_times_out_when_child_is_silent
    @runner = PipeRunner.new
    sup = supervisor(@runner, step_timeout: 0.2)
    handle = sup.open(Object.new)

    err = assert_raises(Freentonic::InvokeError) { sup.send(handle, "page") }
    assert_equal 504, err.status_code
    assert_includes err.message, "timed out"
  end

  def test_send_reports_server_error_when_child_closed
    @runner = PipeRunner.new
    sup = supervisor(@runner)
    handle = sup.open(Object.new)
    @runner.last_handle.child_out.close # child stdout EOF

    err = assert_raises(Freentonic::InvokeError) { sup.send(handle, "page") }
    assert_equal 500, err.status_code
  end

  def test_send_reports_server_error_on_malformed_envelope
    @runner = PipeRunner.new
    sup = supervisor(@runner)
    handle = sup.open(Object.new)
    h = @runner.last_handle
    Thread.new { h.child_in.gets; h.child_out.puts("this is not json"); h.child_out.flush }

    err = assert_raises(Freentonic::InvokeError) { sup.send(handle, "page") }
    assert_equal 500, err.status_code
    assert_includes err.message, "malformed"
  end
end
