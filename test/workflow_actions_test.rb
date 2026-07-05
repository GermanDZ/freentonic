require_relative "test_helper"

module Freentonic
  class WorkflowActionsTest < Minitest::Test
    def schema_with_phase(steps)
      WorkflowSchema.new(path: "/fake/providers/test.yml", raw: {
        "version"  => 1,
        "config"   => { "key" => "test", "default_lookback_days" => 30 },
        "pipeline" => ["login"],
        "phases"   => { "login" => steps }
      })
    end

    # --- unknown-action check ------------------------------------------------

    def test_unknown_action_is_rejected_at_load_time
      err = assert_raises(UserError) do
        schema_with_phase([{ "action" => "navigat", "url" => "https://x" }])
      end
      assert_includes err.message, "unknown action"
      assert_includes err.message, "navigat"
    end

    def test_unknown_action_error_lists_known_actions
      err = assert_raises(UserError) do
        schema_with_phase([{ "action" => "totally_bogus" }])
      end
      assert_includes err.message, "navigate"
    end

    def test_every_known_action_loads_when_required_keys_present
      # A minimal valid step for each registered action must pass validation.
      WorkflowActions.names.each do |action|
        step = { "action" => action }
        minimal_required_values(action).each { |k, v| step[k] = v }
        schema_with_phase([step])
      rescue UserError => e
        flunk "known action #{action.inspect} failed load-time validation: #{e.message}"
      end
    end

    # --- required-key presence for previously-unvalidated actions ------------

    def test_navigate_without_url_is_rejected
      err = assert_raises(UserError) do
        schema_with_phase([{ "action" => "navigate" }])
      end
      assert_includes err.message, "navigate requires url:"
    end

    def test_capture_header_without_as_is_rejected
      err = assert_raises(UserError) do
        schema_with_phase([{ "action" => "capture_header", "name" => "X-Token" }])
      end
      assert_includes err.message, "as:"
    end

    def test_fill_without_value_is_rejected
      err = assert_raises(UserError) do
        schema_with_phase([{ "action" => "fill", "selector" => "#user" }])
      end
      assert_includes err.message, "value:"
    end

    def test_enter_digits_missing_keys_reported_together
      err = assert_raises(UserError) do
        schema_with_phase([{ "action" => "enter_digits" }])
      end
      assert_includes err.message, "digits:"
      assert_includes err.message, "keypad:"
    end

    # --- drift guard: registry <-> runner dispatch ---------------------------

    def test_registry_matches_runner_dispatch_actions
      runner_src = File.read(
        File.expand_path("../lib/freentonic/browser_workflow_runner.rb", __dir__)
      )
      # Only scan the dispatch method so `when` branches elsewhere (event
      # handling, when_context operators) don't leak in.
      dispatch = runner_src[/def execute_step.*?\n      end\n/m]
      refute_nil dispatch, "could not locate execute_step dispatch in runner"
      handled = dispatch.scan(/when "([a-z_]+)"/).flatten.to_set

      registered = WorkflowActions.names.to_set

      assert_empty (registered - handled),
                   "registry lists actions the runner does not dispatch"
      assert_empty (handled - registered),
                   "runner dispatches actions missing from the registry"
    end

    private

    # Minimal set of required-key values good enough to clear both the
    # registry presence check and the bespoke per-action validators.
    def minimal_required_values(action)
      case action
      when "wait"                    then { "seconds" => 1 }
      when "prompt_stdin_and_fill"   then { "selector" => "#otp", "prompt" => "OTP?", "timeout" => 60 }
      when "pause"                   then { "message" => "hold", "timeout" => 60 }
      when "record_requests"         then { "url_matches" => ["/api/"] }
      when "elevate_session"
        { "wait_for_first_of" => { "branches" => [{ "selector" => "#ok" }] } }
      else
        WorkflowActions.required_keys(action).each_with_object({}) do |k, h|
          h[k] = default_value_for(k)
        end
      end
    end

    def default_value_for(key)
      case key
      when "headers", "selectors", "url_matches" then ["#a"]
      when "timeout"                             then 30
      else "x"
      end
    end
  end
end
