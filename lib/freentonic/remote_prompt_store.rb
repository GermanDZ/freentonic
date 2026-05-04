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

    def initialize(prompts_dir:, clock: Time)
      @prompts_dir = prompts_dir
      @clock       = clock
    end

    attr_reader :prompts_dir

    # Block until the server posts a value, the timeout elapses, or the
    # request is aborted by the caller.
    #
    # @param kind [Symbol] :input (returns the submitted string) or
    #                     :confirm (returns true on POST {})
    # @param message [String] human-facing prompt text
    # @param mask [Boolean] hint to clients that the value is sensitive;
    #   advisory only — value is never logged regardless.
    # @param timeout_seconds [Integer]
    # @return [String, true] the submitted value (input) or true (confirm)
    # @raise [Timeout] when no response arrives before the deadline
    class Timeout < StandardError; end

    def prompt(kind:, message:, mask: false, timeout_seconds:)
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

      yield prompt_id, request if block_given?

      response = poll_for_response(prompt_id, deadline: expires_at)
      mark_done(prompt_id, response)

      case kind
      when :input, "input"
        value = response["value"]
        value.is_a?(String) ? value : ""
      when :confirm, "confirm"
        true
      else
        raise ArgumentError, "unknown prompt kind: #{kind.inspect}"
      end
    end

    private

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

    def poll_for_response(prompt_id, deadline:)
      path = response_path(prompt_id)
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
