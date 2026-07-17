# frozen_string_literal: true

require "date"
require "tmpdir"

require_relative "../display_geometry"

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
        elsif @context[:recording]
          # Recording mode: launch CDP Chrome (the recorder needs CDP
          # to inject the probe and read its events via Runtime.addBinding),
          # mask navigator.webdriver, apply the same anti-fingerprint
          # overrides browse mode gets at launch time, install the
          # probe, navigate to the workflow's initial URL, then idle
          # until SIGTERM while draining events into
          # <run_dir>/recording.jsonl.
          launch_chrome
          @chrome_started = true
          open_login_session
          mask_webdriver
          apply_recording_stealth
          install_recorder
          navigate_to_initial_url
          run_recording_idle
        elsif @context[:step]
          # Step mode: launch Chrome exactly as the normal sync path does
          # (same anti-detection posture — launch flags plus the headless UA
          # fix), navigate to the workflow's initial URL, then hold the one
          # CDP session open and drive it a single action at a time from a
          # JSONL REPL (see #run_step_session). This is the observe → act →
          # observe authoring loop; the session survives a failed action so a
          # wrong selector costs one step, not a full re-login.
          launch_chrome
          @chrome_started = true
          open_login_session
          mask_webdriver
          apply_headless_stealth if @context[:headless]
          navigate_to_initial_url(label: "Step")
          run_step_session
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
      rescue Freentonic::ChromeCdp::Error, KeyError => e
        # ChromeCdp::Error — an operational browser-transport failure (CDP
        # timeout / protocol error). KeyError — a workflow step missing a
        # required key (a `step.fetch(...)` in the runner). Both are the
        # operator's problem, so surface them as a clean UserError instead of
        # a raw backtrace (which could otherwise land *after* the operator
        # completed 2FA). Genuine framework bugs raise other exception types
        # and are deliberately left to propagate.
        raise UserError, "Browser workflow failed: #{e.message}"
      ensure
        @recorder&.close rescue nil
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

      # Recording mode stealth overrides. The CDP launch path (used by
      # recording so the probe can be injected) doesn't ship with the
      # browse-mode launch flags (--user-agent, --accept-lang, TZ env).
      # Applying them at runtime via CDP covers what banks fingerprint
      # at the JS / HTTP-header layer:
      #
      #   - Network.setUserAgentOverride spoofs the UA string AND the
      #     UA-CH headers (sec-ch-ua, sec-ch-ua-platform, …) via
      #     userAgentMetadata.platform = "macOS". Without this the UA
      #     string would say macOS but UA-CH would say Linux — a
      #     classic mismatch flag.
      #   - Emulation.setLocaleOverride sets navigator.language /
      #     navigator.languages so they match the IP's expected locale.
      #   - Emulation.setTimezoneOverride makes Intl/Date report
      #     Europe/Madrid instead of UTC.
      #   - Emulation.setDeviceMetricsOverride pins devicePixelRatio
      #     to 1. The earlier "pretend to be Retina (DPR=2)" override
      #     was dropped: at DPR=2 with a 1280×800 backing display the
      #     CSS viewport collapses to 640×400 and Chrome's physical
      #     window blows past the Xvfb dimensions. A plain 1×
      #     "crappy laptop" fingerprint is also a perfectly common
      #     real-customer profile (lots of older Windows machines in
      #     the Spanish banking customer base).
      #
      # NOT covered (would require modifying chrome_cdp.launch_chrome):
      # WebGL vendor/renderer (banks fingerprint these via the canvas
      # test). Fix is to plumb --use-gl=angle / --use-angle=swiftshader
      # through chrome_cdp.
      def apply_recording_stealth
        lang   = ENV.fetch("FREENTONIC_INTERACTIVE_LANG", INTERACTIVE_DEFAULT_LANG)
        tz     = ENV.fetch("FREENTONIC_INTERACTIVE_TZ",   INTERACTIVE_DEFAULT_TZ)
        locale = lang.split(",").first.to_s.split(";").first.to_s.strip
        locale = "es-ES" if locale.empty?

        @session.send_command("Network.setUserAgentOverride", {
          userAgent:      INTERACTIVE_USER_AGENT,
          acceptLanguage: lang,
          userAgentMetadata: {
            brands: [
              { brand: "Not_A Brand",   version: "8" },
              { brand: "Chromium",      version: "147" },
              { brand: "Google Chrome", version: "147" }
            ],
            fullVersion:     "147.0.0.0",
            platform:        "macOS",
            platformVersion: "10.15.7",
            architecture:    "x86",
            bitness:         "64",
            model:           "",
            mobile:          false
          }
        })
        @session.send_command("Emulation.setLocaleOverride",   { locale: locale })
        @session.send_command("Emulation.setTimezoneOverride", { timezoneId: tz })
        emul_w, emul_h = DisplayGeometry.call
        @session.send_command("Emulation.setDeviceMetricsOverride", {
          width:             emul_w,
          height:            emul_h,
          deviceScaleFactor: 1,
          mobile:            false
        })
        stdout.puts "Recording: stealth overrides applied (UA/UA-CH=macOS, lang=#{locale}, tz=#{tz}, dpr=1, viewport=#{emul_w}x#{emul_h})."
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

      # Hold the one CDP session open and drive it a single action at a time
      # from a JSONL REPL. Builds ONE long-lived BrowserWorkflowRunner (the
      # per-runner state — @recording_installed, the debug recorder — must not
      # reset between actions, so it cannot be rebuilt per step) and hands it,
      # plus the step input/output IOs, to a StepSession.
      #
      # Under the CLI the CLI routes the runner's human log lines to stderr and
      # the JSONL envelope channel to stdout, so the two never interleave; the
      # server passes the same IOs down its child's pipes. Teardown (session,
      # Chrome, isolated profile) is the shared `ensure` at the top of #call —
      # the REPL just returns when stdin hits EOF / `quit`.
      def run_step_session
        raise UserError, "--step requires a --workflow" unless source.workflow?

        workflow_context = (@context[:workflow_context] ||= {})
        runtime_context = {
          lookback_days: @context[:lookback_days],
          only_stage:    @context[:only_stage],
          through_stage: @context[:through_stage],
          isolated:      @context[:isolated],
          source_key:    source.key
        }.compact

        runner = BrowserWorkflowRunner.new(
          source: source,
          session: @session,
          schema: source.workflow,
          context: workflow_context,
          runtime_context: runtime_context,
          secret_resolver: @context.fetch(:secret_resolver),
          session_drainer: @context[:session_drainer] || SourceHelpers.method(:drain_session_events),
          stdout: stdout,
          stderr: stderr
        )

        StepSession.new(
          runner: runner,
          input:  @context[:step_input]  || $stdin,
          output: @context[:step_output] || $stdout
        ).run(initial_url: initial_url_from_workflow)
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
        win_w, win_h = DisplayGeometry.call

        # Clear Chromium's singleton-lock sentinels. They live in
        # --user-data-dir and exist to prevent two Chromes from
        # corrupting the same profile; Chrome removes them on a clean
        # exit. But Browse sessions cancelled mid-run (operator clicks
        # Stop, container restart, scheduler SIGTERM) leave the lock
        # symlinks behind, and the *next* Browse launch sees them and
        # bails with "profile in use by another Chromium process",
        # which is why Browse can look like it died randomly on every
        # second attempt. The CDP path does this same cleanup before
        # launch (see chrome_cdp.rb#start); mirror it here.
        %w[SingletonLock SingletonCookie SingletonSocket].each do |f|
          path = File.join(chrome_cdp.profile_dir, f)
          File.delete(path) if File.symlink?(path) || File.exist?(path)
        end

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
          # NOTE: we intentionally do NOT set --force-device-scale-factor
          # here (the CDP/Recording path does). Chrome interprets
          # --window-size in CSS pixels, so DPR=2 with window-size=1280,800
          # makes the physical window 2560×1600 — bigger than the Xvfb
          # display, so the right/bottom edges clip outside what noVNC
          # can show. Browse is human-driven (the operator provides all
          # the legitimate interaction signals), so the anti-bot benefit
          # of pretending to be Retina is much weaker than for Sync.
          # Trade-off: banks see DPR=1, which Windows laptops report
          # natively — still a plausible real-customer fingerprint.
          #
          # We also do NOT set --test-type here even though it would
          # suppress the "unsupported flag --no-sandbox" yellow bar at
          # the top of the page. --test-type is fine for CDP-controlled
          # Chrome (Sync/Record) but on the no-CDP interactive launch
          # it puts Chrome into an automated-testing mode that exits
          # early — i.e. it visibly breaks Browse. Leaving the
          # cosmetic yellow bar is the right tradeoff: the bank page
          # still renders below it and the operator can scroll past.
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
          "--disable-features=UserAgentClientHint",
          # Match the Xvfb display (driven by FREENTONIC_XVFB_GEOMETRY in
          # docker-entrypoint.sh, default 1280x800). Without this,
          # Chromium either picks a smaller default and anchors lower-
          # left (empty desktop margin around the bank UI) or — worse,
          # if we hardcoded a larger value than the Xvfb display —
          # asks for a window the display can't accommodate and Chrome
          # exits, taking the VNC session down with it.
          # --start-maximized would be more idiomatic but Xvfb has no
          # window manager to honor the maximize hint; an explicit size
          # is the reliable form.
          "--window-size=#{win_w},#{win_h}"
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
        stdout.puts "  window:  #{win_w}x#{win_h} (driven by FREENTONIC_XVFB_GEOMETRY)"
        stdout.puts "  display: #{ENV['DISPLAY']}"

        # `TZ` env makes JS `Intl.DateTimeFormat().resolvedOptions().timeZone`
        # return the configured zone — without this it would say UTC,
        # which doesn't match an IP-geolocated Spanish customer and is
        # a classic anti-bot heuristic. Also affects Date()'s offset.
        #
        # Chrome stderr is routed to the run's stderr (which the
        # invoke server captures into the run log) so SIGSEGV / GPU
        # init failures / "Display :99 cannot be opened" / etc. are
        # visible. Previously it went to /dev/null and the run would
        # silently die seconds after launch with no breadcrumb.
        @interactive_chrome_pid = Process.spawn(
          { "TZ" => tz },
          *args,
          out: "/dev/null",
          err: stderr
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
        stdout.puts "  - End the session by closing the Chrome window, or by sending SIGTERM/SIGINT (Ctrl-C from the CLI; POST /cancel/<run_id> when run under the invoke server)."
        if @context[:isolated]
          stdout.puts "  - Profile is isolated: state will NOT persist after exit (the temp profile dir is removed in cleanup)."
        else
          stdout.puts "  - Profile state will persist for subsequent runs."
        end

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

      # Install the recording probe. Writes events to
      # <run_dir>/recording.jsonl when FREENTONIC_RUN_DIR is set
      # (always true under the invoke server). Falls back to a path
      # under the system temp dir for direct CLI use, so a developer
      # running `freentonic --recording` from the shell still gets a
      # capture.
      def install_recorder
        run_dir = ENV["FREENTONIC_RUN_DIR"]
        recording_path =
          if run_dir && !run_dir.empty?
            File.join(run_dir, "recording.jsonl")
          else
            File.join(Dir.tmpdir, "freentonic-recording-#{Process.pid}.jsonl")
          end
        @recorder = Freentonic::Recorder.new(path: recording_path, stdout: stdout)
        @recorder.install(@session)
      end

      def navigate_to_initial_url(label: "Recording")
        url = initial_url_from_workflow
        return unless url
        stdout.puts "#{label}: navigating to #{url}"
        @session.send_command("Page.navigate", { url: url })
      end

      # Recording idle loop. Same shape as run_interactive_browse
      # except instead of sleep(1) we drain the CDP socket every tick
      # so probe events flow into recording.jsonl with low latency.
      def run_recording_idle
        stop = false
        prev_term = trap("TERM") { stop = true }
        prev_int  = trap("INT")  { stop = true }

        stdout.puts "Recording mode: probe is live."
        stdout.puts "  - Drive Chrome by hand via VNC; clicks/fills/navigations are captured."
        stdout.puts "  - End the session by sending SIGTERM (POST /cancel/<run_id> when run under the invoke server)."

        begin
          until stop
            @recorder.drain(@session, timeout: 0.5)
          end
          stdout.puts "Recording mode: cancel signal received, closing."
        ensure
          trap("TERM", prev_term) rescue nil
          trap("INT",  prev_int)  rescue nil
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
