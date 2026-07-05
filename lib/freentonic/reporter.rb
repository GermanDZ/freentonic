# frozen_string_literal: true

require "json"
require "time"

module Freentonic
  # Structured run-event channel for the pipeline.
  #
  # Everything a run does is emitted as a typed event (`stage.start`,
  # `stage.finish`, `phase.start`, `step`, …) carrying an `elapsed_ms` measured
  # from the reporter's birth. One of two sinks renders those events:
  #
  #   * HumanSink  — concise stage-timing lines on stdout. The default; used
  #                  for interactive CLI runs where the detailed `[yml]` step
  #                  logs already serve the operator and we only want to add a
  #                  per-stage timing summary on top.
  #   * NdjsonSink — one JSON object per line appended to
  #                  `<run_dir>/events.ndjson` (0600). Selected when
  #                  FREENTONIC_RUN_DIR is set (i.e. under the invoke server),
  #                  giving the server a machine-readable channel to tail
  #                  alongside the human-readable `log`.
  #
  # Build with .build (env-driven sink selection). Stages that may run without a
  # reporter wired in should fall back to Reporter.null, a no-op that answers
  # every message — so callers never guard with `reporter&.`.
  class Reporter
    # Pick a sink from the environment: NDJSON to <run_dir>/events.ndjson when a
    # run dir is given (the invoke-server child sets FREENTONIC_RUN_DIR), else a
    # concise human summary on stdout. A run dir that can't be opened for the
    # events file degrades to the null sink rather than aborting the run — the
    # human-readable `log` still captures everything.
    def self.build(stdout: $stdout, run_dir: ENV["FREENTONIC_RUN_DIR"])
      sink =
        if run_dir && !run_dir.to_s.empty?
          NdjsonSink.open(run_dir) || NullSink.new
        else
          HumanSink.new(stdout)
        end
      new(sink)
    end

    # A reporter that discards every event. Handed to stages invoked outside the
    # CLI (tests, direct stage construction) so they don't have to nil-check.
    def self.null
      new(NullSink.new)
    end

    def initialize(sink)
      @sink  = sink
      @mutex = Mutex.new
      @t0    = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Emit one event. `name` is a dotted type; the rest are stringified,
    # secret-free fields the caller vouches for. Never raises into the pipeline:
    # a broken sink must not fail a bank login.
    def event(name, **fields)
      payload = { "event" => name.to_s, "elapsed_ms" => elapsed_ms }
      fields.each { |k, v| payload[k.to_s] = v }
      @mutex.synchronize { @sink.write(payload) }
      nil
    rescue StandardError
      nil
    end

    # Time a pipeline stage: stage.start → (block) → stage.finish, or
    # stage.error if the block raises (the exception still propagates). The
    # finish/error event carries the stage's own wall time in `duration_ms`,
    # distinct from `elapsed_ms` (time since the run began).
    def stage(name)
      event("stage.start", stage: name.to_s)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result  = yield
      event("stage.finish", stage: name.to_s, duration_ms: since_ms(started), ok: true)
      result
    rescue StandardError => e
      event("stage.error", stage: name.to_s, duration_ms: since_ms(started), ok: false,
                           error_class: e.class.name, error: e.message)
      raise
    end

    # Time a workflow phase (connect/login/scrape/…). Same shape as #stage but a
    # phase is a group of steps inside the Connect stage.
    def phase(name)
      event("phase.start", phase: name.to_s)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result  = yield
      event("phase.finish", phase: name.to_s, duration_ms: since_ms(started))
      result
    end

    # A single workflow step. `action` is the YAML action name (e.g. "navigate")
    # — never the resolved value, so no secret or URL argument is recorded here.
    # `skipped` is true when a `when_context` guard elided the step.
    def step(action, phase: nil, skipped: false)
      fields = { action: action.to_s }
      fields[:phase]   = phase.to_s if phase
      fields[:skipped] = true if skipped
      event("step", **fields)
    end

    private

    def elapsed_ms
      since_ms(@t0)
    end

    def since_ms(from)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - from) * 1000).to_i
    end

    # ── sinks ────────────────────────────────────────────────

    class NullSink
      def write(_payload); end
      def close; end
    end

    # Concise human summary: only stage boundaries and errors surface, so the
    # per-stage timing rides alongside the detailed [yml] step lines without
    # drowning them. step/phase events are intentionally dropped here.
    class HumanSink
      def initialize(io)
        @io = io
      end

      def write(payload)
        line =
          case payload["event"]
          when "stage.finish"
            "  [freentonic] #{payload["stage"]} ✓ (#{payload["duration_ms"]}ms)"
          when "stage.error"
            "  [freentonic] #{payload["stage"]} ✗ (#{payload["duration_ms"]}ms): #{payload["error_class"]}"
          end
        return unless line
        @io.puts(line)
        @io.flush if @io.respond_to?(:flush)
      end

      def close; end
    end

    # Append-only NDJSON to <run_dir>/events.ndjson, 0600 to match the rest of
    # the codebase's secret-file discipline (the events file names accounts,
    # step actions, and timings — treat it as sensitive as the log).
    class NdjsonSink
      def self.open(run_dir)
        path = File.join(run_dir, "events.ndjson")
        io = File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600)
        io.sync = true
        new(io)
      rescue SystemCallError
        nil
      end

      def initialize(io)
        @io = io
      end

      def write(payload)
        @io.write(JSON.generate(payload) << "\n")
      end

      def close
        @io.close
      rescue StandardError
        nil
      end
    end
  end
end
