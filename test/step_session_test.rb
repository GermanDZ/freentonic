require_relative "test_helper"
require "stringio"
require "json"

module Freentonic
  class StepSessionTest < Minitest::Test
    # Records every step it is asked to run and replays a canned envelope. A
    # step whose selector is "#missing" fails with an attached observation
    # (mirroring BrowserWorkflowRunner#run_action's real contract); everything
    # else succeeds. #observe_page returns a fixed inventory.
    class FakeRunner
      attr_reader :ran

      def initialize(raise_on: nil)
        @ran = []
        @raise_on = raise_on
      end

      def run_action(step)
        @ran << step
        action = step.is_a?(Hash) ? step["action"] : nil
        raise "boom" if @raise_on && action == @raise_on

        if step.is_a?(Hash) && step["selector"] == "#missing"
          { "ok" => false, "action" => action, "error" => "selector not found",
            "observation" => { "url" => "u", "title" => "t", "interactive" => [] } }
        else
          { "ok" => true, "action" => action }
        end
      end

      def observe_page
        { "url" => "https://bank/login", "title" => "Login",
          "interactive" => [{ "selector" => "#dni" }] }
      end
    end

    def drive(input_lines, runner: FakeRunner.new, initial_url: "https://bank/login")
      output = StringIO.new
      StepSession.new(
        runner: runner,
        input: StringIO.new(input_lines),
        output: output
      ).run(initial_url: initial_url)
      [output.string.each_line.map { |l| JSON.parse(l) }, runner]
    end

    def test_ready_envelope_emitted_first
      envelopes, = drive("quit\n")
      assert_equal({ "ok" => true, "ready" => true, "url" => "https://bank/login" },
                   envelopes.first)
    end

    def test_runs_action_and_emits_ok_envelope
      envelopes, runner = drive(%({"action":"click","selector":"#ok"}\n))
      assert_equal({ "ok" => true, "action" => "click" }, envelopes.last)
      assert_equal [{ "action" => "click", "selector" => "#ok" }], runner.ran
    end

    def test_failed_action_envelope_passes_through_with_observation
      envelopes, = drive(%({"action":"click","selector":"#missing"}\n))
      failed = envelopes.last
      assert_equal false, failed["ok"]
      assert_equal "selector not found", failed["error"]
      refute_nil failed["observation"], "a failed step must carry a Tier-1 observation"
    end

    def test_page_command_emits_observation
      envelopes, = drive("page\n")
      page = envelopes.last
      assert_equal true, page["ok"]
      assert_equal "https://bank/login", page["page"]["url"]
      assert_equal "#dni", page["page"]["interactive"].first["selector"]
    end

    def test_accepts_single_line_yaml_flow_mapping
      # A human at the shell can type YAML flow style instead of strict JSON.
      envelopes, runner = drive(%({action: click, selector: "#ok"}\n))
      assert_equal({ "ok" => true, "action" => "click" }, envelopes.last)
      assert_equal "click", runner.ran.last["action"]
    end

    def test_unparseable_line_yields_error_envelope_and_does_not_stop_loop
      envelopes, runner = drive("this is not: [valid\n{\"action\":\"reload\"}\n")
      parse_err = envelopes[1]
      assert_equal false, parse_err["ok"]
      assert_includes parse_err["error"], "could not parse step"
      # The loop survived the bad line and ran the next one.
      assert_equal({ "ok" => true, "action" => "reload" }, envelopes.last)
      assert_equal ["reload"], runner.ran.map { |s| s["action"] }
    end

    def test_quit_ends_loop_without_processing_later_lines
      _, runner = drive(%({"action":"reload"}\nquit\n{"action":"click","selector":"#x"}\n))
      assert_equal ["reload"], runner.ran.map { |s| s["action"] },
                   "no action after `quit` should run"
    end

    def test_exit_is_also_a_quit_word
      _, runner = drive("exit\n{\"action\":\"reload\"}\n")
      assert_empty runner.ran
    end

    def test_eof_ends_loop_cleanly
      # No trailing quit: the loop must end on EOF, not hang.
      envelopes, runner = drive(%({"action":"reload"}\n))
      assert_equal ["reload"], runner.ran.map { |s| s["action"] }
      assert_equal({ "ok" => true, "action" => "reload" }, envelopes.last)
    end

    def test_blank_lines_are_ignored
      _, runner = drive("\n   \n{\"action\":\"reload\"}\n\n")
      assert_equal ["reload"], runner.ran.map { |s| s["action"] }
    end

    def test_unexpected_runner_error_becomes_envelope_and_loop_continues
      runner = FakeRunner.new(raise_on: "reload")
      output = StringIO.new
      StepSession.new(
        runner: runner,
        input: StringIO.new(%({"action":"reload"}\n{"action":"click","selector":"#ok"}\n)),
        output: output
      ).run
      envelopes = output.string.each_line.map { |l| JSON.parse(l) }
      # The reload raised inside the runner; StepSession turned it into an
      # error envelope rather than dying, then ran the next line.
      boom = envelopes.find { |e| e["error"].to_s.include?("boom") }
      refute_nil boom
      assert_equal false, boom["ok"]
      assert(envelopes.any? { |e| e["ok"] && e["action"] == "click" })
    end

    def test_non_mapping_line_is_rejected_by_run_action
      # A bare scalar parses fine (YAML) but is not a step; run_action rejects
      # it — StepSession just forwards whatever run_action returns.
      envelopes, = drive("42\n", runner: RealishRunner.new)
      assert_equal false, envelopes.last["ok"]
      assert_includes envelopes.last["error"], "not a mapping"
    end

    # A minimal stand-in that reproduces run_action's non-Hash rejection, so
    # the test above exercises the forwarding contract without a real runner.
    class RealishRunner
      def run_action(step)
        return { "ok" => false, "action" => nil, "error" => "step is not a mapping" } unless step.is_a?(Hash)

        { "ok" => true, "action" => step["action"] }
      end

      def observe_page = {}
    end

    def test_each_envelope_is_one_json_line
      output = StringIO.new
      StepSession.new(
        runner: FakeRunner.new,
        input: StringIO.new(%({"action":"reload"}\npage\n)),
        output: output
      ).run(initial_url: nil)
      # ready + reload + page = 3 lines, each a standalone JSON object.
      lines = output.string.each_line.to_a
      assert_equal 3, lines.size
      lines.each { |l| assert_kind_of Hash, JSON.parse(l) }
    end
  end
end
