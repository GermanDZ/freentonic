# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "freentonic/invoke_runner"
require "freentonic/simplefin/feature"
require "freentonic/simplefin/sync_queue"

module Freentonic
  module Simplefin
    class SyncQueueTest < Minitest::Test
      # Stand-in runner. Pretends to spawn a child, writes a cache file to
      # simulate the SimpleFIN exporter, and returns a Result struct.
      class FakeRunner
        attr_reader :workflows_dir, :runs, :calls
        attr_accessor :next_exit, :next_error_kind, :cache_dir, :master_key

        def initialize(workflows_dir:, cache_dir:, master_key:)
          @workflows_dir = workflows_dir
          @cache_dir     = cache_dir
          @master_key    = master_key
          @calls         = []
          @next_exit     = 0
          @next_error_kind = nil
          @write_cache   = true
        end

        def skip_cache_write!; @write_cache = false; end

        def run(request)
          @calls << request
          if @write_cache && @next_exit.zero?
            envelope = { "accounts" => [{ "id" => "x", "currency" => "EUR",
                                          "balance" => "0.00",
                                          "balance-date" => Time.now.to_i,
                                          "transactions" => [] }],
                         "errors" => [] }
            path = Paths.cache_path(request.profile_key, @cache_dir)
            FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
            File.write(path, JSON.generate(envelope))
          end
          InvokeRunner::Result.new(
            run_id:      request.run_id,
            exit_code:   @next_exit,
            error_kind:  @next_error_kind,
            duration_ms: 10,
            artifacts:   [],
            log_path:    "runs/#{request.run_id}/log",
            warnings:    [],
            chrome_profile_dir: nil
          )
        end
      end

      def setup
        @root          = Dir.mktmpdir("simplefin-q-")
        @workflows_dir = Dir.mktmpdir("simplefin-q-wf-")
        @workflow_name = "acme/workflow.yml"
        FileUtils.mkdir_p(File.join(@workflows_dir, "acme"))
        File.write(File.join(@workflows_dir, @workflow_name), "source: {}\n")

        @master_key = Crypto.decode_master_key(Crypto.generate_master_key_b64)
        @feature = Feature.new(
          root: @root,
          master_key: @master_key,
          admin_password: "pw",
          public_url: "http://example"
        )
        @feature.profile_store.create(key: "acme", workflow: @workflow_name, lookback_days: 7)
        @feature.profile_store.write_credentials("acme",
          { "USER_DNI" => "1", "USER_PIN" => "2" }, master_key: @master_key)

        @runner = FakeRunner.new(workflows_dir: @workflows_dir,
                                 cache_dir: @root, master_key: @master_key)
        @mutex  = Mutex.new
        @queue  = SyncQueue.new(feature: @feature, runner: @runner,
                                invoke_mutex: @mutex, workflows_dir: @workflows_dir)
        @feature.install_queue(@queue)
      end

      def teardown
        @queue.stop(timeout: 3) if @queue.instance_variable_get(:@thread)
        FileUtils.rm_rf(@root)
        FileUtils.rm_rf(@workflows_dir)
      end

      def wait_until(timeout: 3)
        deadline = Time.now + timeout
        until yield
          raise "condition not met" if Time.now > deadline
          sleep 0.02
        end
      end

      def test_successful_sync_transitions_to_ready
        @queue.start
        @queue.enqueue("acme")
        wait_until { @feature.state_store.read("acme")["state"] == "ready" }
        state = @feature.state_store.read("acme")
        assert_equal "ready", state["state"]
        refute_nil state["last_run_id"]
        assert_equal 1, @runner.calls.size
        # Credentials were decrypted before the InvokeRequest was built.
        creds = @runner.calls.first.credentials_inline
        assert_equal "1", creds["USER_DNI"]
      end

      def test_exit_code_3_transitions_to_needs_reauth
        @runner.next_exit = SyncQueue::NEEDS_REAUTH_EXIT_CODE
        @runner.next_error_kind = "user_error"
        @runner.skip_cache_write!
        @queue.start
        @queue.enqueue("acme")
        wait_until { @feature.state_store.read("acme")["state"] == "needs_reauth" }
        entries = @feature.run_log.recent("acme")
        assert_equal "needs_reauth", entries.first["outcome"]
      end

      def test_other_failures_transition_to_error
        @runner.next_exit = 1
        @runner.next_error_kind = "user_error"
        @runner.skip_cache_write!
        @queue.start
        @queue.enqueue("acme")
        wait_until { @feature.state_store.read("acme")["state"] == "error" }
      end

      def test_enqueue_is_idempotent_while_queued
        # Block the mutex so the job sits in state "running" for a while.
        @mutex.lock
        @queue.start
        assert_equal :enqueued, @queue.enqueue("acme")
        wait_until { @feature.state_store.read("acme")["state"] == "queued" ||
                     @queue.pending_keys.include?("acme") }
        assert_includes %i[already_queued already_active], @queue.enqueue("acme")
        @mutex.unlock
        wait_until { @feature.state_store.read("acme")["state"] == "ready" }
      end

      def test_recover_on_boot_resets_queued_and_running
        @feature.state_store.force_state("acme", "queued")
        @feature.state_store.force_state("other", "running")
        @feature.recover_on_boot!
        assert_equal "idle", @feature.state_store.read("acme")["state"]
        assert_equal "idle", @feature.state_store.read("other")["state"]
      end

      def test_build_request_uses_simplefin_export_mode
        @queue.start
        @queue.enqueue("acme")
        wait_until { @runner.calls.any? }
        request = @runner.calls.first
        assert_equal "simplefin", request.export["mode"]
        assert_equal "acme", request.export["profile_key"]
      end
    end
  end
end
