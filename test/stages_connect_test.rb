# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

module Freentonic
  # Coverage for the parts of the Connect stage that don't need a real
  # Chrome: the pure initial-URL picker, and the error-wrapping contract
  # that turns a browser-transport failure (ChromeCdp::Error) or a
  # workflow-step KeyError into a clean UserError instead of a raw backtrace
  # landing after the operator already completed 2FA.
  class StagesConnectTest < Minitest::Test
    # ─── initial_url_from_workflow ───

    # Source double exposing only what initial_url_from_workflow touches.
    class WorkflowDouble
      def initialize(connect_steps)
        @connect_steps = connect_steps
      end

      def phase(name)
        name == "connect" ? @connect_steps : []
      end
    end

    class SourceDouble
      def initialize(connect_steps: [], has_workflow: true)
        @workflow = WorkflowDouble.new(connect_steps)
        @has_workflow = has_workflow
      end

      def workflow? = @has_workflow
      def workflow  = @workflow
    end

    def connect_stage(source:, **ctx)
      Stages::Connect.new(context: { source: source, stdout: StringIO.new, stderr: StringIO.new }.merge(ctx))
    end

    def initial_url(connect_steps)
      stage = connect_stage(source: SourceDouble.new(connect_steps: connect_steps))
      stage.send(:initial_url_from_workflow)
    end

    def test_initial_url_returns_first_literal_navigate
      url = initial_url([
        { "action" => "wait", "seconds" => 1 },
        { "action" => "navigate", "url" => "https://bank.example/login" },
        { "action" => "navigate", "url" => "https://bank.example/second" }
      ])
      assert_equal "https://bank.example/login", url
    end

    def test_initial_url_skips_secret_interpolated_urls
      # A URL that carries a secret() token can't be opened before the
      # operator authenticates — skip it and fall through.
      url = initial_url([
        { "action" => "navigate", "url" => "https://bank.example/x?t=secret(access_token)" },
        { "action" => "navigate", "url" => "https://bank.example/plain" }
      ])
      assert_equal "https://bank.example/plain", url
    end

    def test_initial_url_nil_when_no_navigate
      assert_nil initial_url([{ "action" => "wait", "seconds" => 1 }])
    end

    def test_initial_url_nil_when_url_empty
      assert_nil initial_url([{ "action" => "navigate", "url" => "" }])
    end

    def test_initial_url_nil_without_workflow
      stage = connect_stage(source: SourceDouble.new(has_workflow: false))
      assert_nil stage.send(:initial_url_from_workflow)
    end

    # ─── error wrapping in #call ───

    # Fake chrome_cdp injected via context[:chrome_cdp]. Raises from
    # launch_chrome so #call's rescue clause is exercised without a browser.
    class FailingChromeCdp
      def initialize(error)
        @error = error
      end

      def configure(**) = nil
      def launch_chrome
        raise @error
      end
    end

    def test_chrome_cdp_error_becomes_user_error
      stage = connect_stage(
        source:      SourceDouble.new,
        chrome_cdp:  FailingChromeCdp.new(ChromeCdp::Error.new("CDP timeout"))
      )
      err = assert_raises(UserError) { stage.call }
      assert_includes err.message, "Browser workflow failed"
      assert_includes err.message, "CDP timeout"
    end

    def test_key_error_becomes_user_error
      stage = connect_stage(
        source:      SourceDouble.new,
        chrome_cdp:  FailingChromeCdp.new(KeyError.new("key not found: \"url\""))
      )
      err = assert_raises(UserError) { stage.call }
      assert_includes err.message, "Browser workflow failed"
    end

    def test_unexpected_error_is_not_swallowed
      # A genuine framework bug (e.g. NoMethodError) must propagate, not be
      # masked as operator error.
      stage = connect_stage(
        source:      SourceDouble.new,
        chrome_cdp:  FailingChromeCdp.new(RuntimeError.new("boom"))
      )
      assert_raises(RuntimeError) { stage.call }
    end
  end
end
