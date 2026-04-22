# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tempfile"
require "yaml"
require "freentonic/invoke_runner"

# Covers the needs_reauth plumbing end-to-end at the framework level:
#   - workflow_schema accepts kind: reauth / rejects bad kinds
#   - browser_workflow_runner's check_error_signals! raises ReauthRequired
#     when a matched signal has kind: reauth
#   - CLI.run maps ReauthRequired to exit code 3
#   - InvokeRunner.classify_error maps exit 3 to "needs_reauth"
#
# Chrome isn't touched here — FakeSession feeds the runtime_* calls.
class ReauthSignalTest < Minitest::Test
  # Minimal session double. Always reports the body contains `body_text`,
  # so a signal with text: "foo" matches iff body_text includes "foo".
  # Returns in the exact {"result": {"value": ...}} shape the real CDP
  # client produces, because handle_runtime_exception! walks that path.
  class FakeSession
    def initialize(body_text:)
      @body_text = body_text
    end

    def send_command(_method, params, **_opts)
      expression = params[:expression] || params["expression"]
      value =
        if expression.include?("document.body")
          # The injected JS is "(text) => document.body.innerText.includes(text)".
          # Extract the JSON-encoded arg from the tail of the expression.
          arg = extract_arg(expression)
          !!(arg && @body_text.include?(arg))
        elsif expression.include?("document.title")
          false
        elsif expression.include?("deepQuery")
          false
        else
          nil
        end
      { "result" => { "value" => value } }
    end

    def method_missing(*); end
    def respond_to_missing?(*); true; end

    private

    def extract_arg(expression)
      # Expression shape: "((fn))(\"needle\")"
      last = expression[/\(([^()]*)\)\z/, 1]
      return nil if last.nil? || last.empty?
      JSON.parse(last) rescue nil
    end
  end

  def write_workflow(extra_config)
    doc = {
      "version"     => 1,
      "config"      => { "key" => "bank" }.merge(extra_config),
      "credentials" => ["USER_DNI"],
      "phases"      => { "connect" => [] },
      "pipeline"    => []
    }
    tmp = Tempfile.new(["wf", ".yml"])
    tmp.write(YAML.dump(doc))
    tmp.close
    tmp
  end

  # ── schema ─────────────────────────────────────────────

  def test_schema_accepts_kind_reauth
    tmp = write_workflow({ "error_signals" => [{ "text" => "expired", "kind" => "reauth" }] })
    schema = Freentonic::WorkflowSchema.load(tmp.path)
    assert_equal "reauth", schema.error_signals.first["kind"]
  ensure
    tmp.unlink
  end

  def test_schema_rejects_unknown_kind
    tmp = write_workflow({ "error_signals" => [{ "text" => "oops", "kind" => "nuclear" }] })
    err = assert_raises(Freentonic::UserError) { Freentonic::WorkflowSchema.load(tmp.path) }
    assert_match(/kind:/, err.message)
  ensure
    tmp.unlink
  end

  # ── runner raises the right class ──────────────────────

  def test_runner_raises_reauth_required_on_kind_reauth
    tmp = write_workflow({ "error_signals" => [{ "text" => "session expired", "kind" => "reauth" }] })
    schema  = Freentonic::WorkflowSchema.load(tmp.path)
    runner  = build_runner(schema, body_text: "session expired")

    err = assert_raises(Freentonic::ReauthRequired) do
      runner.send(:check_error_signals!)
    end
    assert_match(/Re-authentication required/i, err.message)
  ensure
    tmp.unlink
  end

  def test_runner_still_raises_user_error_for_default_kind
    tmp = write_workflow({ "error_signals" => [{ "text" => "blocked" }] })
    schema = Freentonic::WorkflowSchema.load(tmp.path)
    runner = build_runner(schema, body_text: "blocked")

    err = assert_raises(Freentonic::UserError) { runner.send(:check_error_signals!) }
    refute_kind_of Freentonic::ReauthRequired, err
    assert_match(/Screen error detected/, err.message)
  ensure
    tmp.unlink
  end

  # ── CLI exit code mapping ──────────────────────────────

  def test_cli_exits_3_for_reauth_required
    cli = Freentonic::Cli.new(stdout: StringIO.new, stderr: StringIO.new)
    cli.define_singleton_method(:parse) { |_argv| raise Freentonic::ReauthRequired, "needs re-login" }
    cli.define_singleton_method(:validate!) { |_| }
    cli.define_singleton_method(:execute) { |_| }
    assert_equal 3, cli.run([])
  end

  def test_classify_error_maps_exit_three_to_needs_reauth
    assert_equal "needs_reauth",
      Freentonic::InvokeRunner.classify_error(3, false, false)
  end

  private

  def build_runner(schema, body_text:)
    session = FakeSession.new(body_text: body_text)
    runner = Freentonic::BrowserWorkflowRunner.new(
      source:          FakeSource.new,
      session:         session,
      schema:          schema,
      context:         {},
      secret_resolver: nil,
      session_drainer: ->(*) {},
      stdout:          StringIO.new,
      stderr:          StringIO.new
    )
    # save_screenshot talks to Chrome and writes to disk; neither matters
    # for the error-signal dispatch we're testing here.
    runner.define_singleton_method(:save_screenshot) { |_label| nil }
    runner.instance_variable_set(:@last_error_signal_check, Time.at(0))
    runner
  end

  FakeSource = Struct.new(:key) do
    def initialize(key = "bank"); super; end
  end
end
