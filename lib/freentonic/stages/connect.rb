# frozen_string_literal: true

require "date"

module Freentonic
  module Stages
    # Connect stage: launches Chrome via CDP, runs the YAML-declared
    # login/capture pipeline via BrowserWorkflowRunner, and extracts the
    # resolved credentials hash. Writes context[:credentials].
    #
    # Produces context[:credentials] = { access_token: ..., cookie: ..., ... }
    class Connect < Base
      CHROME_READY_TIMEOUT_SECONDS = 45
      DEFAULT_CDP_PORT = 9222

      def call
        configure_chrome
        launch_chrome
        @chrome_started = true
        open_login_session
        run_pipeline
        @context[:credentials] = extract_credentials
        @context
      ensure
        @session&.close rescue nil
        close_chrome if @chrome_started
      end

      private

      def chrome_cdp
        @context[:chrome_cdp] || Freentonic::ChromeCdp
      end

      def configure_chrome
        chrome_cdp.configure(
          port: @context[:cdp_port] || DEFAULT_CDP_PORT,
          isolated: @context[:isolated] || false
        )
      end

      def launch_chrome
        mode = @context[:isolated] ? "isolated temp profile" : "system profile"
        stdout.puts "Launching Chrome (#{mode})..."

        result = chrome_cdp.launch_chrome
        if result == :attached
          stdout.puts "  ✓ Attached to running Chrome (debug port already open)"
        else
          stdout.print "  Waiting for Chrome debug port"
          unless chrome_cdp.wait_for_chrome_ready(timeout: CHROME_READY_TIMEOUT_SECONDS)
            raise UserError, "Chrome did not respond on debug port after #{CHROME_READY_TIMEOUT_SECONDS}s."
          end
          stdout.puts " ✓"
        end
      end

      def open_login_session
        ws_url = chrome_cdp.find_first_page_target
        @session = chrome_cdp.open_session(ws_url)
        @session.send_command("Network.enable")
        @session.send_command("Page.enable")
      end

      def close_chrome
        stdout.puts "Closing Chrome..."
        chrome_cdp.kill_chrome
      end

      def run_pipeline
        return unless source.workflow?

        workflow_context = (@context[:workflow_context] ||= {})
        runtime_context = {
          lookback_days: @context[:lookback_days],
          only_stage:    @context[:only_stage],
          through_stage: @context[:through_stage],
          isolated:      @context[:isolated],
          source_key:    source.key
        }.compact

        source.workflow.pipeline.each do |phase|
          BrowserWorkflowRunner.new(
            source: source,
            session: @session,
            schema: source.workflow,
            context: workflow_context,
            runtime_context: runtime_context,
            secret_resolver: @context.fetch(:secret_resolver),
            session_drainer: @context[:session_drainer] || SourceHelpers.method(:drain_session_events),
            stdout: stdout,
            stderr: stderr
          ).execute_phase(phase)
        end
      end

      def extract_credentials
        source.extract_credentials(
          @session,
          workflow_context: @context[:workflow_context] || {},
          stdout: stdout,
          stderr: stderr
        )
      end
    end
  end
end
