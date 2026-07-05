# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "json"

module Freentonic
  # Focused coverage for Engine's offline-replay input loading. The rest of the
  # pipeline is exercised through the stage tests and the example integration
  # test; here we only pin that a bad --from-raw / --from-normalized path
  # becomes a clean UserError instead of an uncaught Errno / JSON backtrace.
  class EngineTest < Minitest::Test
    def load_inputs(context)
      Engine.new(context: context).send(:load_serialized_inputs!)
    end

    def test_from_raw_malformed_json_is_user_error
      Dir.mktmpdir do |d|
        path = File.join(d, "raw.json")
        File.write(path, "{ this is not json")
        err = assert_raises(UserError) { load_inputs(from_raw: path) }
        assert_includes err.message, "--from-raw"
        assert_includes err.message, "not valid JSON"
      end
    end

    def test_from_raw_missing_file_is_user_error
      err = assert_raises(UserError) { load_inputs(from_raw: "/no/such/raw.json") }
      assert_includes err.message, "--from-raw"
      assert_includes err.message, "file not found"
    end

    def test_from_normalized_malformed_json_is_user_error
      Dir.mktmpdir do |d|
        path = File.join(d, "normalized.json")
        File.write(path, "not json at all")
        err = assert_raises(UserError) { load_inputs(from_normalized: path) }
        assert_includes err.message, "--from-normalized"
      end
    end

    def test_valid_from_raw_loads_into_context
      Dir.mktmpdir do |d|
        path = File.join(d, "raw.json")
        File.write(path, JSON.generate("accounts" => []))
        context = { from_raw: path }
        Engine.new(context: context).send(:load_serialized_inputs!)
        assert_equal({ "accounts" => [] }, context[:raw])
      end
    end

    # ─── stages_to_run: the stage-skip matrix ───
    #
    # The heart of the offline-replay / partial-run feature. Pure decision
    # logic over the context hash, so it's worth pinning every branch.

    def stages(context)
      Engine.new(context: context).send(:stages_to_run)
    end

    def test_default_runs_full_pipeline_in_order
      assert_equal %i[connect elevate extract normalize export], stages({})
    end

    def test_only_stage_runs_exactly_one
      assert_equal [:extract], stages(only_stage: :extract)
    end

    def test_only_stage_accepts_string_and_symbolizes
      assert_equal [:normalize], stages(only_stage: "normalize")
    end

    def test_through_stage_runs_prefix_inclusive
      assert_equal %i[connect elevate extract normalize], stages(through_stage: :normalize)
    end

    def test_through_connect_runs_only_connect
      assert_equal [:connect], stages(through_stage: :connect)
    end

    def test_unknown_through_stage_is_user_error
      err = assert_raises(UserError) { stages(through_stage: :bogus) }
      assert_includes err.message, "unknown stage"
    end

    def test_from_raw_skips_connect_and_extract
      # Replaying a raw dump: Connect + Extract are meaningless (we already
      # have the raw payload), so only Normalize + Export remain.
      assert_equal %i[normalize export], stages(from_raw: "/tmp/raw.json")
    end

    def test_from_normalized_skips_through_normalize
      # Replaying a normalized dump: everything upstream of Export is skipped.
      assert_equal [:export], stages(from_normalized: "/tmp/n.json")
    end

    def test_interactive_forces_connect_only
      # Browse mode short-circuits at Connect even though no only_stage is set;
      # the downstream stages would NoMethodError on the nil credentials hash.
      assert_equal [:connect], stages(interactive: true)
    end

    def test_recording_forces_connect_only
      assert_equal [:connect], stages(recording: true)
    end

    def test_interactive_wins_over_through_stage
      # interactive/recording override an explicit --through.
      assert_equal [:connect], stages(interactive: true, through_stage: :export)
    end

    def test_only_stage_intersected_with_from_raw_skip
      # only_stage names a skipped stage → the skip set wins and it drops out,
      # yielding an empty run rather than re-running a stage from_raw excludes.
      assert_equal [], stages(only_stage: :extract, from_raw: "/tmp/raw.json")
    end

    # ─── reporter integration ───
    #
    # Pin that Engine frames the run and each stage with structured events. We
    # stub run_stage so no real stage machinery is needed — the point is the
    # event envelope, not the stage bodies.

    class RecordingSink
      attr_reader :events
      def initialize = @events = []
      def write(payload) = @events << payload
    end

    def run_with_recorder(context)
      sink = RecordingSink.new
      engine = Engine.new(context: context.merge(reporter: Reporter.new(sink)))
      ran = []
      engine.define_singleton_method(:run_stage) { |name| ran << name }
      engine.run
      [sink.events, ran]
    end

    def test_engine_frames_run_and_stages_with_events
      events, ran = run_with_recorder(only_stage: :extract)
      assert_equal [:extract], ran
      names = events.map { |e| e["event"] }
      assert_equal %w[pipeline.start stage.start stage.finish pipeline.finish], names
      assert_equal "extract", events[1]["stage"]
      assert_equal true, events[2]["ok"]
      assert_kind_of Integer, events[2]["duration_ms"]
    end

    def test_pipeline_start_lists_planned_stages
      events, = run_with_recorder(through_stage: :normalize)
      assert_equal %w[connect elevate extract normalize], events.first["stages"]
    end
  end
end
