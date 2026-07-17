# frozen_string_literal: true

require "json"

require_relative "invoke_request" # for InvokeError

module Freentonic
  # Server-side driver for one held-open `freentonic --step` child. Wraps an
  # InvokeRunner (which owns the process + pipe mechanics) and speaks the JSONL
  # step protocol over the child's stdin/stdout:
  #
  #   open(request)          → spawn, block until the child's {"ready":true}
  #                            envelope, return the StepHandle
  #   send(handle, message)  → write one protocol line, read one envelope back
  #   close(handle)          → tear the child down
  #
  # The InvokeServer's /sessions endpoints orchestrate lifecycle (one session
  # at a time, idle watchdog, auth) and call these three methods. Injecting a
  # fake supervisor is how the server is tested without a real Chrome.
  #
  # Read timeouts bound the two blocking waits so a wedged or dead child can't
  # pin a request handler forever: READY_TIMEOUT covers Chrome launch +
  # navigation on open; STEP_TIMEOUT comfortably exceeds any single action's
  # own internal wait ceiling (wait_url/wait_for_selector default ~30s) on
  # send. The child emits exactly one envelope per input line — even a failed
  # action — so the only way a read times out is a genuinely stuck/dead child.
  class StepSessionSupervisor
    READY_TIMEOUT = 90
    STEP_TIMEOUT  = 120

    def initialize(runner:, ready_timeout: READY_TIMEOUT, step_timeout: STEP_TIMEOUT)
      @runner        = runner
      @ready_timeout = ready_timeout
      @step_timeout  = step_timeout
    end

    def open(request, &on_start)
      handle = @runner.open_step_session(request, &on_start)
      ready  = read_envelope(handle, @ready_timeout)
      unless ready.is_a?(Hash) && ready["ready"]
        close(handle)
        raise InvokeError.new(:server_error, "step session did not report ready")
      end
      handle
    rescue InvokeError
      raise
    rescue StandardError => e
      close(handle) if handle
      raise InvokeError.new(:server_error, "failed to open step session: #{e.message}")
    end

    # Write one raw protocol line (a JSON action object, or "page") and read
    # back exactly one envelope. Raises InvokeError(:timeout) if the child
    # produces nothing in time, (:server_error) if it has gone away.
    def send(handle, message)
      handle.stdin.puts(message)
      handle.stdin.flush
      read_envelope(handle, @step_timeout)
    rescue Errno::EPIPE, IOError
      raise InvokeError.new(:server_error, "step session is not accepting input (child gone)")
    end

    def close(handle)
      @runner.close_step_session(handle)
    end

    private

    def read_envelope(handle, timeout)
      ready = IO.select([handle.stdout], nil, nil, timeout)
      raise InvokeError.new(:timeout, "step session timed out after #{timeout}s") unless ready

      line = handle.stdout.gets
      raise InvokeError.new(:server_error, "step session closed unexpectedly") if line.nil?

      JSON.parse(line)
    rescue JSON::ParserError => e
      raise InvokeError.new(:server_error, "malformed envelope from step session: #{e.message}")
    end
  end
end
