# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "../invoke_request"

module Freentonic
  module Simplefin
    # In-memory fire-and-forget sync queue. A single worker thread pops
    # profile keys and runs each through InvokeRunner#run under the shared
    # @invoke_mutex — preserving the "one Chrome at a time" invariant.
    #
    # The queue is deliberately in-memory: SimpleFIN clients re-enqueue on
    # every call, so a restart simply loses pending work and Actual's next
    # Sync click puts it back.
    class SyncQueue
      # Custom exit code for "needs re-authentication" — the providers emit
      # this via the error_signals workflow feature. 3 is outside Ruby's
      # conventional 1 (UserError) / 2 (ExportError) exit codes and is
      # translated into state `needs_reauth` by the worker below.
      NEEDS_REAUTH_EXIT_CODE = 3

      Job = Struct.new(:profile_key, :headed, :trigger, :vnc_password, keyword_init: true)

      def initialize(
        feature:,
        runner:,
        invoke_mutex:,
        workflows_dir: nil
      )
        @feature       = feature
        @runner        = runner
        @invoke_mutex  = invoke_mutex
        @workflows_dir = workflows_dir || (runner.respond_to?(:workflows_dir) ? runner.workflows_dir : nil)

        @queue_mutex = Mutex.new
        @queue_cv    = ConditionVariable.new
        @queue       = []
        @stopping    = false
        @thread      = nil
        @active_key  = nil
        # @active_job is richer than @active_key — includes run_id, headed,
        # vnc_password, started_at so the admin UI can surface a VNC link
        # and a live-log pointer without having to poll run_log.recent.
        @active_job  = nil
      end

      def start
        @thread ||= Thread.new { run_loop }
        self
      end

      def stop(timeout: 30)
        @queue_mutex.synchronize do
          @stopping = true
          @queue_cv.broadcast
        end
        @thread&.join(timeout)
        @thread = nil
      end

      # Enqueue a sync for a profile. No-op when the profile is already
      # queued or running — keeps the idempotency contract the GET /accounts
      # handler relies on.
      def enqueue(profile_key, headed: false, trigger: "auto", vnc_password: nil)
        Paths.validate_component!(profile_key, "profile_key")
        @queue_mutex.synchronize do
          return :already_active if @active_key == profile_key
          return :already_queued if @queue.any? { |j| j.profile_key == profile_key }
          @queue << Job.new(profile_key: profile_key, headed: headed,
                            trigger: trigger, vnc_password: vnc_password)
          @queue_cv.signal
        end
        @feature.state_store.update(profile_key) do |state|
          next :abort if state["state"] == "running"
          state.merge("state" => "queued", "last_error" => nil)
        end
        :enqueued
      end

      def pending_keys
        @queue_mutex.synchronize { @queue.map(&:profile_key) }
      end

      def active_key
        @queue_mutex.synchronize { @active_key.dup }
      end

      # Snapshot of the currently-running job (if any). Admin status
      # surfaces this so the UI can show a Watch-live (VNC) link and a
      # live log tail without having to guess at run_ids.
      def active_job
        @queue_mutex.synchronize { @active_job ? @active_job.dup : nil }
      end

      # ── worker ───────────────────────────────────────────────

      private

      def run_loop
        loop do
          job = @queue_mutex.synchronize do
            @queue_cv.wait(@queue_mutex) while @queue.empty? && !@stopping
            return if @stopping && @queue.empty?
            popped = @queue.shift
            @active_key = popped&.profile_key
            popped
          end
          break unless job
          process_job(job)
        ensure
          @queue_mutex.synchronize do
            @active_key = nil
            @active_job = nil
          end
        end
      rescue StandardError => e
        @feature.log("queue worker crashed: #{e.class}: #{e.message}")
        raise
      end

      def process_job(job)
        profile = @feature.profile_store.read(job.profile_key)
        unless profile
          @feature.log("job skipped: profile #{job.profile_key} missing")
          return
        end

        @feature.state_store.force_state(job.profile_key, "running",
          "last_error" => nil, "started_at" => Time.now.utc.iso8601)

        run_id = "simplefin-#{job.profile_key}-#{SecureRandom.hex(6)}"

        # Publish rich active-job info the moment the run_id is minted, so
        # an admin-UI poll can show "Watch live" + "Live log" right away.
        @queue_mutex.synchronize do
          @active_job = {
            profile_key: job.profile_key,
            run_id:      run_id,
            headed:      !!job.headed,
            vnc_password: job.headed ? job.vnc_password : nil,
            trigger:     job.trigger,
            started_at:  Time.now.utc.iso8601
          }
        end

        begin
          request = build_request(profile, job, run_id: run_id)
        rescue StandardError => e
          fail_job(job.profile_key, run_id, "error", "request setup failed: #{e.message}", exit_code: nil)
          return
        end

        result = nil
        started_at = Time.now
        begin
          @invoke_mutex.synchronize do
            result = @runner.run(request)
          end
        rescue Freentonic::InvokeError => e
          fail_job(job.profile_key, run_id, classify_state_from_runner(e),
                   "#{e.kind}: #{e.message}", exit_code: nil, started_at: started_at)
          return
        rescue StandardError => e
          @feature.log("sync #{run_id} crashed: #{e.class}: #{e.message}")
          fail_job(job.profile_key, run_id, "error",
                   "#{e.class}: #{e.message}", exit_code: nil, started_at: started_at)
          return
        end

        finished_at = Time.now
        exit_code   = result.exit_code
        if exit_code.to_i.zero?
          @feature.cache_store.exists?(job.profile_key) ||
            @feature.log("sync #{run_id} succeeded but no cache file was produced")
          @feature.state_store.force_state(job.profile_key, "ready",
            "last_run_id" => run_id, "last_error" => nil,
            "last_synced_at" => finished_at.utc.iso8601)
          @feature.run_log.record(job.profile_key,
            run_id: run_id,
            started_at: started_at.utc.iso8601,
            finished_at: finished_at.utc.iso8601,
            duration_ms: ((finished_at - started_at) * 1000).to_i,
            exit_code: exit_code,
            error_kind: nil,
            outcome: "ready",
            message: "sync ok",
            headed: job.headed)
        elsif exit_code == NEEDS_REAUTH_EXIT_CODE
          finish_failure(job, run_id, started_at, finished_at, result,
            outcome: "needs_reauth",
            message: "workflow emitted needs_reauth signal")
        else
          finish_failure(job, run_id, started_at, finished_at, result,
            outcome: "error",
            message: "exit #{exit_code}#{result.error_kind ? " (#{result.error_kind})" : ""}")
        end
      end

      def finish_failure(job, run_id, started_at, finished_at, result, outcome:, message:)
        @feature.state_store.force_state(job.profile_key, outcome,
          "last_run_id" => run_id, "last_error" => message,
          "last_synced_at" => finished_at.utc.iso8601)
        @feature.run_log.record(job.profile_key,
          run_id: run_id,
          started_at: started_at.utc.iso8601,
          finished_at: finished_at.utc.iso8601,
          duration_ms: ((finished_at - started_at) * 1000).to_i,
          exit_code: result.exit_code,
          error_kind: result.error_kind,
          outcome: outcome,
          message: message,
          headed: job.headed)
      end

      def fail_job(profile_key, run_id, outcome, message, exit_code:, started_at: nil)
        now = Time.now
        @feature.state_store.force_state(profile_key, outcome,
          "last_run_id" => run_id, "last_error" => message,
          "last_synced_at" => now.utc.iso8601)
        @feature.run_log.record(profile_key,
          run_id: run_id,
          started_at: (started_at || now).utc.iso8601,
          finished_at: now.utc.iso8601,
          duration_ms: started_at ? ((now - started_at) * 1000).to_i : 0,
          exit_code: exit_code,
          error_kind: "setup",
          outcome: outcome,
          message: message,
          headed: false)
      end

      def classify_state_from_runner(error)
        # Runner-level failures (bad workflow path, missing workspace) are
        # not bank-session problems — keep them as `error`, not `needs_reauth`.
        "error"
      end

      def build_request(profile, job, run_id:)
        body = {
          "run_id"      => run_id,
          "workflow"    => profile.fetch("workflow"),
          "profile_key" => profile.fetch("profile_key"),
          "lookback"    => profile["lookback_days"],
          "credentials" => { "inline" => decrypted_credentials(profile) },
          "export"      => {
            "mode"        => "simplefin",
            "profile_key" => profile.fetch("profile_key")
          },
          "chrome"      => { "headless" => !job.headed }
        }
        body.delete("lookback") if body["lookback"].nil?
        # Only set vnc_password when the operator asked for a headed sync.
        # Default behaviour (headless auto-sync) inherits the runner's
        # random-unreachable sentinel, locking VNC down between invokes.
        body["vnc_password"] = job.vnc_password if job.headed && job.vnc_password
        Freentonic::InvokeRequest.from_hash(body, workflows_dir: @workflows_dir)
      end

      def decrypted_credentials(profile)
        @feature.profile_store.read_credentials(profile.fetch("profile_key"),
          master_key: @feature.master_key)
      end
    end
  end
end
