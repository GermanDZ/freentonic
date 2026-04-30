# frozen_string_literal: true

require "json"
require "fileutils"

module Freentonic
  # Recording mode plumbing.
  #
  # Owns one CDP session shared with Connect, installs a JS probe via
  # Page.addScriptToEvaluateOnNewDocument, and drains
  # Runtime.consoleAPICalled + Page.frameNavigated events into
  # <run_dir>/recording.jsonl. Single-threaded by design — Connect's
  # idle loop calls #drain in a tight loop instead of us spinning a
  # parallel reader on the same WebSocket.
  #
  # File format is JSON-lines: one event per line. Each line is either
  # a probe event (kind: click | fill | submit | probe_ready) or a
  # synthetic recorder event (kind: navigate | recorder_*).
  class Recorder
    PROBE_PATH = File.expand_path("recorder/probe.js", __dir__)
    PROBE_PREFIX = "__freentonic_rec__:"

    # `path` is the absolute path to the recording.jsonl file
    # (typically <run_dir>/recording.jsonl). Created O_APPEND with mode
    # 0600 so multiple drain() ticks append atomically and credentials
    # adjacent in the JSONL aren't world-readable.
    def initialize(path:, stdout: $stdout)
      @path = path
      @stdout = stdout
      @file = nil
      @installed = false
      @probe_source = File.read(PROBE_PATH)
    end

    # Open the JSONL sink, enable the CDP domains we need, and install
    # the probe so it runs on every new document the operator visits.
    # Idempotent — calling install twice is a no-op past the first.
    def install(session)
      return if @installed
      FileUtils.mkdir_p(File.dirname(@path))
      @file = File.open(@path, File::WRONLY | File::CREAT | File::APPEND, 0o600)
      session.send_command("Runtime.enable")
      session.send_command("Page.enable")
      session.send_command("Page.addScriptToEvaluateOnNewDocument", { source: @probe_source })
      append({ "kind" => "recorder_started", "t" => (Time.now.to_f * 1000).to_i })
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
      when "Runtime.consoleAPICalled"
        handle_console(parsed["params"] || {})
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

    def handle_console(params)
      args = params["args"] || []
      first = args.first || {}
      return unless first["type"] == "string"
      raw = first["value"].to_s
      return unless raw.start_with?(PROBE_PREFIX)
      payload = JSON.parse(raw[PROBE_PREFIX.length..])
      append(payload)
    rescue JSON::ParserError
      # malformed probe event — silently drop; operator can re-record
    end

    def append(payload)
      return unless @file
      @file.puts(JSON.generate(payload))
      @file.flush
    end
  end
end
