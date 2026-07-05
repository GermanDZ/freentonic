# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

module Freentonic
  # Coverage for the Export *stage* fan-out (distinct from the individual
  # exporter classes tested in exporters_test.rb). The documented contract:
  # every exporter runs even if an earlier one fails, and the *first* error
  # is re-raised only after all exporters have had their turn — so a failing
  # HTTP push never suppresses a local JSON dump (or vice versa).
  class StagesExportTest < Minitest::Test
    # Records whether it ran; optionally raises ExportError.
    class FakeExporter
      attr_reader :ran
      def initialize(fail_with: nil)
        @fail_with = fail_with
        @ran = false
      end

      def write(_payload)
        @ran = true
        raise ExportError, @fail_with if @fail_with
        :ok
      end
    end

    def run_stage(exporters, normalized: { "accounts" => [] })
      ctx = {
        normalized: normalized,
        exporters:  exporters,
        stdout:     StringIO.new,
        stderr:     StringIO.new
      }
      Stages::Export.new(context: ctx).call
      ctx
    end

    def test_all_exporters_run_on_success
      a = FakeExporter.new
      b = FakeExporter.new
      ctx = run_stage([a, b])
      assert a.ran
      assert b.ran
      assert_equal [:ok, :ok], ctx[:export_results]
    end

    def test_failing_exporter_does_not_short_circuit_later_ones
      failing = FakeExporter.new(fail_with: "boom")
      after    = FakeExporter.new
      err = assert_raises(ExportError) { run_stage([failing, after]) }
      assert_equal "boom", err.message
      # The exporter after the failing one must still have run.
      assert after.ran, "exporter after a failure should still run"
    end

    def test_first_error_is_the_one_reraised
      first  = FakeExporter.new(fail_with: "first-failure")
      second = FakeExporter.new(fail_with: "second-failure")
      err = assert_raises(ExportError) { run_stage([first, second]) }
      assert_equal "first-failure", err.message
      assert second.ran
    end

    def test_missing_normalized_payload_is_user_error
      err = assert_raises(UserError) do
        ctx = { exporters: [FakeExporter.new], stdout: StringIO.new, stderr: StringIO.new }
        Stages::Export.new(context: ctx).call
      end
      assert_includes err.message, "no normalized payload"
    end

    def test_no_exporters_configured_is_user_error
      err = assert_raises(UserError) { run_stage([]) }
      assert_includes err.message, "no exporters configured"
    end

    def test_success_leaves_no_export_results_key_untouched_on_failure
      # On partial failure the stage raises before assigning :export_results.
      ctx = {
        normalized: { "accounts" => [] },
        exporters:  [FakeExporter.new(fail_with: "x")],
        stdout:     StringIO.new,
        stderr:     StringIO.new
      }
      assert_raises(ExportError) { Stages::Export.new(context: ctx).call }
      refute ctx.key?(:export_results)
    end
  end
end
