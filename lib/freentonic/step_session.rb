# frozen_string_literal: true

require "json"
require "yaml"

module Freentonic
  # Line-delimited read-eval-print loop over ONE long-lived
  # BrowserWorkflowRunner, for held-open authoring sessions. It is the engine
  # behind both front-ends:
  #
  #   * the CLI:  `freentonic --step --workflow draft.yml` (Stages::Connect
  #     step mode wires stdin/stdout to it), and
  #   * the invoke server: POST /sessions spawns `freentonic --step` as a
  #     child and proxies JSONL over its stdin/stdout.
  #
  # Protocol (one message per line — JSON on the wire; the CLI also accepts a
  # single-line YAML flow mapping so a human can type `{action: click,
  # selector: "#x"}`):
  #
  #   IN   {"action":"click","selector":"#x"}   run one workflow action
  #   IN   page                                  emit a Tier-1 page observation
  #   IN   quit | exit | (EOF)                   clean teardown, loop ends
  #   OUT  {"ok":true,"ready":true,"url":...}    emitted once, session is live
  #   OUT  {"ok":true,"action":"click"}          action succeeded
  #   OUT  {"ok":false,"action":..,"error":..,"observation":{...}}  action failed
  #   OUT  {"ok":true,"page":{...}}              page observation
  #   OUT  {"ok":false,"error":"could not parse step: ..."}         unparseable line
  #
  # The loop NEVER raises out to its caller: parse errors, action failures, and
  # even an unexpected exception mid-step all become an {"ok":false,...}
  # envelope so a single bad line can't tear down a held session (the whole
  # point — a wrong selector should cost one line, not a re-login). Teardown of
  # Chrome/CDP is the caller's job (Stages::Connect's ensure block); this class
  # only drives the conversation.
  class StepSession
    # A one-message-per-line output is only useful if each envelope is flushed
    # the instant it is written — the server proxy blocks on reading exactly
    # one line back per request, and a buffered write would deadlock it.
    def initialize(runner:, input:, output:)
      @runner = runner
      @input  = input
      @output = output
    end

    # Drive the loop until EOF / quit. `initial_url` is reported in the ready
    # envelope only (Connect has already navigated there); it is not fetched.
    def run(initial_url: nil)
      emit("ok" => true, "ready" => true, "url" => initial_url)

      while (line = @input.gets)
        message = line.strip
        next if message.empty?

        break if QUIT_WORDS.include?(message)

        emit(handle(message))
      end
    end

    private

    QUIT_WORDS = %w[quit exit].freeze

    def handle(message)
      return page_envelope if message == "page"

      step = parse_step(message)
      @runner.run_action(step)
    rescue ParseError => e
      { "ok" => false, "error" => "could not parse step: #{e.message}" }
    rescue StandardError => e
      # run_action rescues the expected action failures itself; anything that
      # still escapes is unexpected, but a held session should report it and
      # keep going rather than die. The next line (or a `quit`) can recover.
      { "ok" => false, "error" => "#{e.class}: #{e.message}" }
    end

    def page_envelope
      { "ok" => true, "page" => @runner.observe_page }
    end

    # JSON first (the server's wire format, strict), single-line YAML flow
    # mapping as a human-typing fallback. YAML goes through safe_load with its
    # default guards (no aliases, no arbitrary object instantiation) untouched.
    # A non-Hash parse (a bare word, a number) is passed through to run_action,
    # which rejects it with a clean "step is not a mapping" envelope.
    def parse_step(message)
      begin
        return JSON.parse(message)
      rescue JSON::ParserError
        # fall through to the YAML flow-mapping form
      end

      YAML.safe_load(message)
    rescue Psych::Exception => e
      raise ParseError, e.message
    end

    def emit(envelope)
      @output.puts(JSON.generate(envelope))
      @output.flush if @output.respond_to?(:flush)
    end

    class ParseError < StandardError; end
  end
end
