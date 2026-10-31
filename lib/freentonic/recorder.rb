# frozen_string_literal: true

require "json"
require "fileutils"

module Freentonic
  # Recording mode plumbing.
  #
  # Owns one CDP session shared with Connect, installs a JS probe via
  # Page.addScriptToEvaluateOnNewDocument, and drains
  # Runtime.bindingCalled + Page.frameNavigated events into
  # <run_dir>/recording.jsonl. Single-threaded by design — Connect's
  # idle loop calls #drain in a tight loop instead of us spinning a
  # parallel reader on the same WebSocket.
  #
  # Exfiltration uses Runtime.addBinding (the puppeteer-stealth
  # channel) instead of console.info: page scripts that hook the
  # console object can't see binding calls, and the probe deletes the
  # binding off `window` immediately after capturing the reference so
  # it doesn't show up in `Object.keys(window)` either.
  #
  # File format is JSON-lines: one event per line. Each line is either
  # a probe event (kind: click | fill | submit | probe_ready) or a
  # synthetic recorder event (kind: navigate | recorder_*).
  class Recorder
    PROBE_PATH = File.expand_path("recorder/probe.js", __dir__)

    # Shared selector heuristics, concatenated into the probe in place of
    # the `__FREENTONIC_SHARED_SELECTORS__` marker so the recorder and the
    # page observer derive selectors from byte-identical source.
    SHARED_SELECTORS_PATH = File.expand_path("recorder/selectors.js", __dir__)
    SHARED_SELECTORS_MARKER = "// __FREENTONIC_SHARED_SELECTORS__"

    # Per-step DOM snapshots. When enabled the probe attaches a serialized
    # deep DOM (light + open shadow roots, input VALUES stripped) to each
    # interaction event; the recorder peels it off into
    # <run_dir>/dom/<session>/NNNN.html (0600; <session> is the recorder's
    # start time in epoch ms, so a later recording into the same run dir
    # never overwrites an earlier one's snapshots) and leaves a `dom_ref` on
    # the JSONL line so tooling can reprocess
    # the exact page a step acted on to mine better field selectors. The probe
    # reads the boolean spliced in at this marker. OFF unless the caller opts
    # in (the author container defaults it on via FREENTONIC_RECORD_DOM=1).
    RECORD_DOM_MARKER = "__FREENTONIC_RECORD_DOM__"
    DOM_SUBDIR = "dom"
    # Guardrail so a runaway page can't fill the workspace; the probe also
    # caps its own serialization, this is the server-side backstop.
    MAX_DOM_BYTES = 4 * 1024 * 1024

    # Name of the CDP binding the probe calls to ship events. Has to
    # be unique enough that a page script can't accidentally call it
    # before the probe captures the reference (Chrome exposes the
    # binding to every world, so a clever page could in principle race
    # to call window.__freentonic_rec_send__ — but the binding payload
    # would just be appended to the recording, not affect normal
    # operation, so the impact is "noise in the recording", not a
    # security issue).
    BINDING_NAME = "__freentonic_rec_send__"

    # `path` is the absolute path to the recording.jsonl file
    # (typically <run_dir>/recording.jsonl). Created O_APPEND with mode
    # 0600 so multiple drain() ticks append atomically and credentials
    # adjacent in the JSONL aren't world-readable.
    def initialize(path:, stdout: $stdout, record_dom: ENV["FREENTONIC_RECORD_DOM"] == "1")
      @path = path
      @stdout = stdout
      @file = nil
      @installed = false
      @record_dom = record_dom
      @dom_dir = nil # per recording session, set by #install
      @dom_seq = 0
      # Block form of sub so the shared source (which contains backslash
      # escapes in cssEscape) isn't reinterpreted as replacement
      # backreferences.
      shared = File.read(SHARED_SELECTORS_PATH)
      @probe_source = File.read(PROBE_PATH)
                          .sub(SHARED_SELECTORS_MARKER) { shared }
                          .sub(RECORD_DOM_MARKER) { @record_dom ? "true" : "false" }
    end

    # Open the JSONL sink, enable the CDP domains we need, register
    # the exfiltration binding, and install the probe so it runs on
    # every new document. Order matters: the binding has to exist
    # before the script runs in the first document, otherwise the
    # probe's `typeof send !== "function"` check trips and the run
    # records nothing.
    def install(session)
      return if @installed
      FileUtils.mkdir_p(File.dirname(@path))
      @file = File.open(@path, File::WRONLY | File::CREAT | File::APPEND, 0o600)
      session.send_command("Runtime.enable")
      session.send_command("Page.enable")
      session.send_command("Runtime.addBinding", { name: BINDING_NAME })
      session.send_command("Page.addScriptToEvaluateOnNewDocument", { source: @probe_source })
      started_ms = (Time.now.to_f * 1000).to_i
      @dom_dir = File.join(File.dirname(@path), DOM_SUBDIR, started_ms.to_s)
      append({ "kind" => "recorder_started", "t" => started_ms })
      @stdout.puts "Recorder: probe injected, writing to #{@path}"
      @installed = true
    end

    # Drain CDP frames into the JSONL sink. First flushes anything
    # send_command buffered into @pending_events (events that arrived
    # mid-command) and then tries to read one new frame from the
    # socket within `timeout`. The caller (Connect's idle loop) keeps
    # calling drain in a tight loop — each call returns within
    # `timeout` so cancel-signal and chrome-alive checks fire on the
    # same cadence the non-recording interactive idle loop uses.
    #
    # Returns true if any event was processed, false on a clean
    # timeout with nothing waiting.
    def drain(session, timeout: 0.5)
      processed = false
      while (ev = session.pending_events.shift)
        handle(ev)
        processed = true
      end

      raw = begin
        ChromeCdp.ws_read_text(session.socket, timeout: timeout)
      rescue StandardError => e
        # ws_read_text raises with "timed out" when no frame arrives
        # in the window — that's the steady-state idle case, swallow
        # it. Anything else is a real socket error worth recording.
        message = e.message.to_s
        return processed if message.include?("timed out")
        append({
          "kind"  => "recorder_error",
          "error" => "#{e.class}: #{message.slice(0, 200)}",
          "t"     => (Time.now.to_f * 1000).to_i
        })
        return processed
      end

      parsed = JSON.parse(raw)
      handle(parsed)
      true
    rescue JSON::ParserError
      # Malformed CDP frame — already off the wire; drop and let the
      # next drain() call try again.
      processed
    end

    def close
      return unless @file
      append({ "kind" => "recorder_stopped", "t" => (Time.now.to_f * 1000).to_i })
      @file.close
      @file = nil
    end

    private

    def handle(parsed)
      method = parsed["method"]
      return unless method
      case method
      when "Runtime.bindingCalled"
        handle_binding(parsed["params"] || {})
      when "Page.frameNavigated"
        frame = parsed.dig("params", "frame") || {}
        # Only record top-level navigations (parentId nil/empty); sub-
        # frames are noisy and rarely meaningful for replay.
        return if frame["parentId"] && !frame["parentId"].empty?
        url = frame["url"]
        return if url.nil? || url.empty? || url == "about:blank"
        append({
          "kind" => "navigate",
          "url"  => url,
          "t"    => (Time.now.to_f * 1000).to_i
        })
      end
    end

    def handle_binding(params)
      return unless params["name"] == BINDING_NAME
      raw = params["payload"]
      return unless raw.is_a?(String)
      payload = JSON.parse(raw)
      offload_dom!(payload)
      append(payload)
    rescue JSON::ParserError
      # malformed probe event — silently drop; operator can re-record
    end

    # Peel a probe event's inline `dom` string into its own file and replace
    # it with a `dom_ref` so recording.jsonl stays a compact one-line-per-event
    # log. Best-effort: a write failure drops the snapshot (the event line and
    # the rest of the recording are unaffected). The file holds page STRUCTURE
    # only (the probe strips input values) but can still carry visible page
    # text, so it inherits the 0600 + workspace-only discipline of the
    # recording itself.
    def offload_dom!(payload)
      dom = payload.delete("dom")
      return unless dom.is_a?(String) && !dom.empty?
      dom = dom.byteslice(0, MAX_DOM_BYTES) if dom.bytesize > MAX_DOM_BYTES
      @dom_seq += 1
      FileUtils.mkdir_p(@dom_dir, mode: 0o700)
      abs = File.join(@dom_dir, format("%04d.html", @dom_seq))
      # EXCL + NOFOLLOW: never write through a pre-planted file or symlink —
      # the 0600 mode only applies to a file this call creates.
      File.open(abs, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |f| f.write(dom) }
      payload["dom_ref"] = abs.delete_prefix("#{File.dirname(@path)}/")
    rescue StandardError => e
      @stdout.puts "Recorder: could not write DOM snapshot (#{e.class}); continuing without it"
    end

    def append(payload)
      return unless @file
      @file.puts(JSON.generate(payload))
      @file.flush
    end
  end
end
