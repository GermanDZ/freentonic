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
        if @context[:interactive]
          # Browse mode bypasses the CDP path entirely — banks
          # fingerprint the open --remote-debugging-port and
          # `navigator.webdriver` even with stealth flags. The user
          # drives Chrome by hand via VNC, so we don't need
          # automation hooks at all. See #launch_interactive_chrome.
          launch_interactive_chrome
          run_interactive_browse
        else
          launch_chrome
          @chrome_started = true
          open_login_session
          mask_webdriver
          apply_headless_stealth if @context[:headless]
          run_pipeline
          @context[:credentials] = extract_credentials
        end
        @context
      rescue RuntimeError => e
        raise UserError, "Browser workflow failed: #{e.message}"
      ensure
        @session&.close rescue nil
        close_chrome if @chrome_started
        if @context[:interactive]
          cleanup_interactive_chrome if @interactive_chrome_pid
          # Always run isolated-profile cleanup on the interactive
          # path: configure_chrome may have created the temp dir
          # before launch_interactive_chrome ever ran, and the CDP
          # close path that normally handles this is bypassed here.
          # No-op when --isolated wasn't set.
          chrome_cdp.cleanup_isolated_profile! if chrome_cdp.respond_to?(:cleanup_isolated_profile!)
        end
      end

      private

      def chrome_cdp
        @context[:chrome_cdp] || Freentonic::ChromeCdp
      end

      def configure_chrome
        chrome_cdp.configure(
          port: @context[:cdp_port] || DEFAULT_CDP_PORT,
          isolated: @context[:isolated] || false,
          headless: @context[:headless] || false,
          no_sandbox: @context[:no_sandbox] || false
        )
      end

      def launch_chrome
        mode = @context[:isolated] ? "isolated temp profile" : "system profile"
        mode = "headless, #{mode}" if @context[:headless]
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

      # Chrome sets navigator.webdriver = true whenever --remote-debugging-port
      # is used, even in non-headless mode. Banking captchas check this property.
      # Mask it unconditionally.
      def mask_webdriver
        @session.send_command("Page.addScriptToEvaluateOnNewDocument", {
          source: "Object.defineProperty(navigator, 'webdriver', { get: () => false })"
        })
      end

      # In headless mode, also mask the "HeadlessChrome" User-Agent string
      # that Chrome sends, which many banking sites block server-side.
      def apply_headless_stealth
        result = @session.send_command("Runtime.evaluate", {
          expression: "navigator.userAgent"
        })
        headless_ua = result.dig("result", "value") || ""
        headed_ua = headless_ua.gsub("HeadlessChrome", "Chrome")
        @session.send_command("Network.setUserAgentOverride", { userAgent: headed_ua })
      end

      def close_chrome
        stdout.puts "Closing Chrome..."
        chrome_cdp.close_gracefully(@session)
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

      # Browse-mode user-agent override. Banks fingerprint:
      #   - the User-Agent header (UA string)
      #   - the navigator.userAgentData (UA-CH) which leaks platform
      # We can't fully fix UA-CH from a Chrome flag, but a UA override
      # at least makes the request line look like a normal macOS Chrome
      # instead of "X11; Linux aarch64" (the Colima/M-series default,
      # rare among real banking customers). Picking macOS Chrome 147 to
      # match the actual binary version installed in the container.
      INTERACTIVE_USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
        "(KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

      # Sensible defaults for Spanish banks (the current set of
      # supported providers — ING, Fintonic, Revolut ES, Unicaja).
      # All overridable via env so users in other locales can match
      # their bank's expected client locale without forking the code.
      INTERACTIVE_DEFAULT_LANG = "es-ES,es;q=0.9,en;q=0.5"
      INTERACTIVE_DEFAULT_TZ   = "Europe/Madrid"

      # Spawn Chrome for interactive (browse) mode WITHOUT
      # --remote-debugging-port, --disable-blink-features, --test-type,
      # or any of the other automation hooks the CDP path adds. Banks
      # fingerprint those even when navigator.webdriver is masked — and
      # the operator is going to drive Chrome by hand through VNC, so
      # we don't need automation at all. The result looks like a
      # vanilla user-launched Chrome to anti-bot heuristics, with the
      # operator's persistent profile loaded.
      def launch_interactive_chrome
        url   = initial_url_from_workflow
        lang  = ENV.fetch("FREENTONIC_INTERACTIVE_LANG", INTERACTIVE_DEFAULT_LANG)
        tz    = ENV.fetch("FREENTONIC_INTERACTIVE_TZ",   INTERACTIVE_DEFAULT_TZ)

        args = [
          chrome_cdp.chrome_binary,
          "--user-data-dir=#{chrome_cdp.profile_dir}",
          "--no-first-run",
          "--no-default-browser-check",
          "--user-agent=#{INTERACTIVE_USER_AGENT}",
          # `--accept-lang` populates BOTH the HTTP Accept-Language
          # header and `navigator.languages`. Without it, Chromium
          # ships an empty-ish default that flags as "fresh container,
          # no real user" against banks that fingerprint locale.
          "--accept-lang=#{lang}",
          # Pretend to be a Retina (2× DPI) display — vanishingly few
          # real banking customers are on 1× monitors in 2026. The
          # real Xvfb display stays 1920×1080; this just changes what
          # CSS / window.devicePixelRatio reports.
          "--force-device-scale-factor=2",
          # Mute the User-Agent Client Hints headers (sec-ch-ua,
          # sec-ch-ua-platform, sec-ch-ua-mobile, …). The `--user-agent`
          # flag above only spoofs the legacy UA string; UA-CH would
          # otherwise still report `"Linux"` as the platform, which
          # contradicts our claimed-macOS UA and reads as bot. Trade-
          # off: no UA-CH at all is also unusual for Chrome 147, but
          # it's a less-targeted signal than an explicit Linux leak —
          # plenty of privacy-minded users disable UA-CH via uBO or
          # similar. The proper fix is the puppeteer-stealth-style
          # extension that spoofs the values; that's roadmap.
          "--disable-features=UserAgentClientHint"
        ]
        if @context[:no_sandbox]
          # --no-sandbox is mandatory for Chrome inside an unprivileged
          # container; --disable-dev-shm-usage routes /tmp instead of
          # the small /dev/shm. We deliberately omit --disable-gpu —
          # even though it's container-safer, it shows up as "no GPU"
          # in WebGL fingerprints.
          args << "--no-sandbox"
          args << "--disable-dev-shm-usage"
          # Force ANGLE-on-SwiftShader for WebGL. Without an explicit
          # flag, Chromium-in-Xvfb gives up on WebGL entirely (the
          # bot.sannysoft.com canvas tests come back "no webgl context"
          # — which itself is a strong bot signal, since virtually
          # every real browser supports WebGL). With this, navigator
          # reports a working "Google Inc." vendor + "ANGLE
          # (Google, Vulkan/SwiftShader Device)" renderer, which is
          # the same combo many real users in low-power / VM setups
          # get. `--enable-unsafe-swiftshader` opts into the software
          # path that newer Chromium otherwise hides behind a flag.
          args << "--use-gl=angle"
          args << "--use-angle=swiftshader"
          args << "--enable-unsafe-swiftshader"
        end
        args << url if url

        stdout.puts "Launching Chrome (interactive — no CDP, no automation hooks)..."
        stdout.puts "  binary:  #{chrome_cdp.chrome_binary}"
        stdout.puts "  profile: #{chrome_cdp.profile_dir}"
        stdout.puts "  url:     #{url || '(none — opens to new tab)'}"
        stdout.puts "  lang:    #{lang}"
        stdout.puts "  tz:      #{tz}"

        # `TZ` env makes JS `Intl.DateTimeFormat().resolvedOptions().timeZone`
        # return the configured zone — without this it would say UTC,
        # which doesn't match an IP-geolocated Spanish customer and is
        # a classic anti-bot heuristic. Also affects Date()'s offset.
        @interactive_chrome_pid = Process.spawn(
          { "TZ" => tz },
          *args,
          out: "/dev/null",
          err: "/dev/null"
        )
        # Detach so the kernel reaps the child as soon as it exits.
        # Without this, an operator-closed Chrome lingers as a zombie
        # and `Process.kill(0, pid)` keeps returning success against
        # the zombie entry — so the idle loop would never notice the
        # window was closed and would stall until the parent's invoke
        # timeout. After detach, kill(0) raises ESRCH once the reaper
        # thread has waited the child, which the alive? check
        # already converts into "false".
        Process.detach(@interactive_chrome_pid)
      end

      # Sleep until cancelled, the parent's invoke timeout fires, or
      # the operator closes Chrome from inside the VNC session. The
      # SIGTERM trap is installed BEFORE we sleep so a cancel issued
      # before Chrome fully boots still exits cleanly.
      def run_interactive_browse
        stop = false
        prev_term = trap("TERM") { stop = true }
        prev_int  = trap("INT")  { stop = true }

        stdout.puts "Interactive mode: Chrome is open and idle."
        stdout.puts "  - Take over via VNC."
        stdout.puts "  - POST /cancel/<run_id> on the parent (or close the Chrome window) when done; Chrome closes cleanly and the profile state is preserved."
        stdout.puts "  - Otherwise the parent's invoke timeout (default 30 min) will fire."

        begin
          until stop
            break unless interactive_chrome_alive?
            sleep 1
          end
          stdout.puts "Interactive mode: closing Chrome (#{stop ? 'cancel signal received' : 'Chrome window closed by user'})."
        ensure
          trap("TERM", prev_term) rescue nil
          trap("INT",  prev_int)  rescue nil
        end
      end

      def interactive_chrome_alive?
        return false unless @interactive_chrome_pid
        Process.kill(0, @interactive_chrome_pid)
        true
      rescue Errno::ESRCH, Errno::ECHILD
        false
      end

      def cleanup_interactive_chrome
        pid = @interactive_chrome_pid
        return unless pid
        begin
          Process.kill("TERM", pid)
        rescue Errno::ESRCH
          return  # already gone
        end
        # Brief grace; SIGKILL if needed. The child is already
        # `Process.detach`'d, so its reaper thread will waitpid for
        # us — we can't waitpid here (would raise ECHILD), so we
        # poll with kill(0) which flips to ESRCH once the reaper
        # has cleaned up the PID entry.
        20.times do
          break unless interactive_chrome_alive?
          sleep 0.1
        end
        Process.kill("KILL", pid) rescue nil if interactive_chrome_alive?
      end

      # Pluck the navigate URL out of the workflow's `connect` phase so
      # we can pass it as Chrome's startup URL. Skips entries whose URL
      # has secret() interpolation — for those the operator can navigate
      # manually after Chrome opens. Most provider workflows have a
      # plain literal URL here (the bank's login page).
      def initial_url_from_workflow
        return nil unless source.workflow?
        steps = source.workflow.phase("connect")
        steps.each do |step|
          next unless step["action"] == "navigate"
          url = step["url"]
          return url if url.is_a?(String) && !url.empty? && !url.include?("secret(")
        end
        nil
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
