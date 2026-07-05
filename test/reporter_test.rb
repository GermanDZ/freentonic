# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"
require "json"

module Freentonic
  class ReporterTest < Minitest::Test
    # A sink that just records every payload, so we can assert on the structured
    # event stream independent of any rendering.
    class CapturingSink
      attr_reader :events
      def initialize = @events = []
      def write(payload) = @events << payload
    end

    def cap
      sink = CapturingSink.new
      [Reporter.new(sink), sink]
    end

    # ── event shape ──────────────────────────────────────────

    def test_event_carries_name_and_elapsed_ms
      reporter, sink = cap
      reporter.event("thing.happened", detail: "x")
      assert_equal 1, sink.events.size
      e = sink.events.first
      assert_equal "thing.happened", e["event"]
      assert_kind_of Integer, e["elapsed_ms"]
      assert_operator e["elapsed_ms"], :>=, 0
      assert_equal "x", e["detail"]
    end

    def test_event_never_raises_into_caller
      broken = Object.new
      def broken.write(_) = raise "sink exploded"
      # Must swallow the sink failure — a broken channel can't fail a bank login.
      assert_nil Reporter.new(broken).event("x")
    end

    # ── stage block ──────────────────────────────────────────

    def test_stage_emits_start_and_finish_with_duration
      reporter, sink = cap
      result = reporter.stage(:extract) { 42 }
      assert_equal 42, result
      names = sink.events.map { |e| e["event"] }
      assert_equal %w[stage.start stage.finish], names
      finish = sink.events.last
      assert_equal "extract", finish["stage"]
      assert_equal true, finish["ok"]
      assert_kind_of Integer, finish["duration_ms"]
    end

    def test_stage_emits_error_and_reraises
      reporter, sink = cap
      err = assert_raises(RuntimeError) { reporter.stage(:connect) { raise "kaboom" } }
      assert_equal "kaboom", err.message
      names = sink.events.map { |e| e["event"] }
      assert_equal %w[stage.start stage.error], names
      error = sink.events.last
      assert_equal "connect", error["stage"]
      assert_equal false, error["ok"]
      assert_equal "RuntimeError", error["error_class"]
      assert_equal "kaboom", error["error"]
    end

    # ── phase + step ─────────────────────────────────────────

    def test_phase_wraps_start_and_finish
      reporter, sink = cap
      reporter.phase("login") { :ok }
      names = sink.events.map { |e| e["event"] }
      assert_equal %w[phase.start phase.finish], names
      assert_equal "login", sink.events.last["phase"]
    end

    def test_step_records_action_and_phase_but_not_arguments
      reporter, sink = cap
      reporter.step("navigate", phase: "login")
      e = sink.events.first
      assert_equal "step", e["event"]
      assert_equal "navigate", e["action"]
      assert_equal "login", e["phase"]
      refute e.key?("skipped")
    end

    def test_skipped_step_is_flagged
      reporter, sink = cap
      reporter.step("click", phase: "login", skipped: true)
      assert_equal true, sink.events.first["skipped"]
    end

    # ── sink selection via build ─────────────────────────────

    def test_build_without_run_dir_uses_human_sink_on_stdout
      io = StringIO.new
      reporter = Reporter.build(stdout: io, run_dir: nil)
      reporter.event("stage.start", stage: "extract") # human sink ignores start
      reporter.event("stage.finish", stage: "extract", duration_ms: 12, ok: true)
      out = io.string
      refute_includes out, "stage.start"
      assert_includes out, "extract"
      assert_includes out, "12ms"
    end

    def test_human_sink_renders_stage_error
      io = StringIO.new
      reporter = Reporter.build(stdout: io, run_dir: nil)
      reporter.event("stage.error", stage: "connect", duration_ms: 5, ok: false,
                                     error_class: "ChromeCdp::Error", error: "boom")
      assert_includes io.string, "connect"
      assert_includes io.string, "ChromeCdp::Error"
    end

    # ── NDJSON sink ──────────────────────────────────────────

    def test_build_with_run_dir_writes_ndjson_file
      Dir.mktmpdir do |dir|
        reporter = Reporter.build(stdout: StringIO.new, run_dir: dir)
        reporter.stage(:extract) { reporter.step("navigate", phase: "scrape") }

        path = File.join(dir, "events.ndjson")
        assert File.file?(path), "expected events.ndjson to be written"

        lines = File.readlines(path).map { |l| JSON.parse(l) }
        names = lines.map { |e| e["event"] }
        assert_equal %w[stage.start step stage.finish], names
        assert lines.all? { |e| e.key?("elapsed_ms") }
      end
    end

    def test_ndjson_file_is_owner_only
      Dir.mktmpdir do |dir|
        Reporter.build(stdout: StringIO.new, run_dir: dir).event("x")
        mode = File.stat(File.join(dir, "events.ndjson")).mode & 0o777
        assert_equal 0o600, mode
      end
    end

    def test_build_with_unwritable_run_dir_degrades_to_null
      # A run dir that can't hold the events file must not abort the run.
      reporter = Reporter.build(stdout: StringIO.new, run_dir: "/no/such/dir/at/all")
      assert_nil reporter.event("x") # no raise
    end

    # ── null reporter ────────────────────────────────────────

    def test_null_reporter_is_safe
      r = Reporter.null
      assert_nil r.event("x")
      assert_equal 7, r.stage(:extract) { 7 }
      assert_equal 9, r.phase("p") { 9 }
      assert_nil r.step("navigate")
    end
  end
end
