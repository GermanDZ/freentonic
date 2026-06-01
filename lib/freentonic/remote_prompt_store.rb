# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"

module Freentonic
  # Filesystem-based rendezvous between the workflow runner subprocess and
  # the invoke server, used to fulfill interactive prompts (SMS code entry,
  # 2FA push approval) when no controlling TTY is available.
  #
  # Wire shape (under <run_dir>/prompts/):
  #
  #   <prompt_id>.request.json   — written atomically by the runner; read by
  #                                the server's GET /runs/{run_id}/prompts.
  #   <prompt_id>.response.json  — written atomically by the server's
  #                                POST /runs/{run_id}/prompts/{id}; read by
  #                                the runner's poll loop.
  #   <prompt_id>.done           — created by the runner after consumption,
  #                                with the value field stripped, as an
  #                                audit breadcrumb.
  #
  # The store never logs the response value and renames the response file to
  # `.done` (with `value` redacted) the moment it's consumed, so the value
  # exists on disk only for the few hundred milliseconds between POST and
  # the next polling tick.
  class RemotePromptStore
    POLL_INTERVAL_SECONDS = 0.25
    PROMPT_ID_BYTES       = 12 # 24 hex chars; collision-safe within a run
    # The response file is polled every POLL_INTERVAL_SECONDS so an operator
    # click stays snappy, but the until_satisfied condition (a CDP roundtrip
    # in practice) is throttled to this coarser cadence — checking the URL 4×/s
    # for a 5-minute wait would be hundreds of needless roundtrips.
    UNTIL_CHECK_INTERVAL_SECONDS = 1.5

    # @param prompts_dir [String] absolute path to <run_dir>/prompts
    # @param announce_to [IO, nil] when non-nil, every prompt() call writes a
    #   `[freentonic][prompt] {...}` JSON-line to this IO *before* polling
    #   for the response. simplefreen-invoke parses these lines out of the
    #   runner's stderr to surface prompts in the admin UI; without an
    #   announcement, prompts opened by a backgrounded extractor are
    #   invisible to the operator. Pass `nil` (default) to skip announcing
    #   — useful for unit tests and for callers that want to drive the
    #   announcement themselves via the prompt() block argument.
    def initialize(prompts_dir:, announce_to: nil, clock: Time)
      @prompts_dir = prompts_dir
      @announce_to = announce_to
      @clock       = clock
    end

    attr_reader :prompts_dir

    # Block until the server posts a value, the timeout elapses, or the
    # request is aborted by the caller.
    #
    # @param kind [Symbol] :input (returns the submitted string),
    #                     :confirm (returns true on POST {}), or :await
    #                     (returns true on POST {} or when until_satisfied
    #                     fires — see below)
    # @param message [String] human-facing prompt text
    # @param mask [Boolean] hint to clients that the value is sensitive;
    #   advisory only — value is never logged regardless.
    # @param timeout_seconds [Integer]
    # @param until_satisfied [#call, nil] optional self-resolving condition.
    #   When given, it is polled (throttled — see UNTIL_CHECK_INTERVAL_SECONDS)
    #   alongside the operator's response file: the moment it returns truthy
    #   the prompt resolves on its own, the request file is withdrawn (so any
    #   watching client clears the card), and prompt() returns true without an
    #   operator action. Used for "waiting on an external event" prompts — e.g.
    #   a phone push approval that flips the browser URL — where the operator
    #   click is only a fallback. The callable is the caller's responsibility
    #   (it's where any CDP/IO happens); the store never inspects it beyond
    #   truthiness and never logs it.
    # @return [String, true] the submitted value (input) or true (confirm/await)
    # @raise [Timeout] when no response arrives before the deadline
    class Timeout < StandardError; end

    def prompt(kind:, message:, mask: false, timeout_seconds:, until_satisfied: nil)
      ensure_dir
      prompt_id = "p_#{SecureRandom.hex(PROMPT_ID_BYTES)}"
      created_at = @clock.now.utc
      expires_at = created_at + timeout_seconds

      request = {
        "prompt_id"  => prompt_id,
        "kind"       => kind.to_s,
        "message"    => message,
        "mask"       => mask ? true : false,
        "created_at" => created_at.iso8601,
        "expires_at" => expires_at.iso8601
      }
      write_json_atomic(request_path(prompt_id), request)

      announce(prompt_id, request) if @announce_to
      yield prompt_id, request if block_given?

      response = poll_for_response(prompt_id, deadline: expires_at, until_satisfied: until_satisfied)
      # :satisfied means the condition fired before any operator response —
      # there's no response file, just withdraw the request as a `.done`
      # breadcrumb so watching clients stop rendering the card.
      mark_done(prompt_id, response == :satisfied ? {} : response)
      return true if response == :satisfied

      case kind
      when :input, "input"
        value = response["value"]
        value.is_a?(String) ? value : ""
      when :confirm, "confirm", :await, "await"
        true
      else
        raise ArgumentError, "unknown prompt kind: #{kind.inspect}"
      end
    end

    private

    # Emit the JSON-line announcement that simplefreen-invoke watches for
    # on the runner's stderr. Best-effort: a broken IO must not fail the
    # prompt itself.
    def announce(prompt_id, request)
      payload = {
        "prompt_id"  => prompt_id,
        "kind"       => request["kind"],
        "message"    => request["message"],
        "mask"       => request["mask"],
        "expires_at" => request["expires_at"]
      }
      @announce_to.puts "[freentonic][prompt] #{JSON.generate(payload)}"
      @announce_to.flush if @announce_to.respond_to?(:flush)
    rescue StandardError
      nil
    end

    def ensure_dir
      return if Dir.exist?(@prompts_dir)
      FileUtils.mkdir_p(@prompts_dir, mode: 0o700)
    end

    def request_path(prompt_id)
      File.join(@prompts_dir, "#{prompt_id}.request.json")
    end

    def response_path(prompt_id)
      File.join(@prompts_dir, "#{prompt_id}.response.json")
    end

    def done_path(prompt_id)
      File.join(@prompts_dir, "#{prompt_id}.done")
    end

    def write_json_atomic(path, payload)
      tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
        f.write(JSON.generate(payload))
      end
      File.rename(tmp, path)
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp) && !File.exist?(path)
    end

    # Returns the parsed operator response, or the :satisfied sentinel when
    # the optional until_satisfied condition fires first. An operator response
    # already on disk always wins over the condition (checked first each tick),
    # so a click that lands in the same tick as the URL flipping is honored.
    def poll_for_response(prompt_id, deadline:, until_satisfied: nil)
      path = response_path(prompt_id)
      last_until_check = nil
      loop do
        if File.file?(path)
          raw = File.read(path)
          begin
            return JSON.parse(raw)
          rescue JSON::ParserError
            # The server only writes well-formed JSON via write_json_atomic,
            # but if a partially-written file ever shows up, treat it as
            # pending and keep polling.
          end
        end
        if until_satisfied
          now = @clock.now
          if last_until_check.nil? || now - last_until_check >= UNTIL_CHECK_INTERVAL_SECONDS
            last_until_check = now
            return :satisfied if until_satisfied.call
          end
        end
        if @clock.now > deadline
          raise Timeout, "remote prompt #{prompt_id} timed out"
        end
        sleep POLL_INTERVAL_SECONDS
      end
    end

    # Drop a `.done` breadcrumb with the value redacted. Best-effort —
    # we never want a cleanup failure to break a successful login.
    def mark_done(prompt_id, response)
      redacted = response.merge("value" => nil, "consumed_at" => @clock.now.utc.iso8601)
      write_json_atomic(done_path(prompt_id), redacted)
      File.unlink(response_path(prompt_id)) rescue nil
      File.unlink(request_path(prompt_id))  rescue nil
    rescue StandardError
      nil
    end
  end
end
