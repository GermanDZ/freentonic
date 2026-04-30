require_relative "test_helper"
require "tmpdir"
require "json"

module Freentonic
  class RemotePromptStoreTest < Minitest::Test
    def setup
      @tmp = Dir.mktmpdir("rps-test")
      @prompts_dir = File.join(@tmp, "prompts")
    end

    def teardown
      FileUtils.rm_rf(@tmp)
    end

    def store
      RemotePromptStore.new(prompts_dir: @prompts_dir)
    end

    def test_writes_request_file_with_expected_shape
      yielded_id = nil
      yielded_request = nil

      thread = Thread.new do
        store.prompt(kind: :input, message: "Code?", mask: true, timeout_seconds: 5) do |id, request|
          yielded_id = id
          yielded_request = request
        end
      end

      wait_for_request(yielded_id_proc: -> { yielded_id }, timeout: 2)

      request_path = File.join(@prompts_dir, "#{yielded_id}.request.json")
      assert File.file?(request_path), "request file should exist"
      payload = JSON.parse(File.read(request_path))
      assert_equal yielded_id, payload["prompt_id"]
      assert_equal "input", payload["kind"]
      assert_equal "Code?", payload["message"]
      assert_equal true, payload["mask"]
      assert payload["created_at"]
      assert payload["expires_at"]

      # Now respond and confirm consumption
      response_path = File.join(@prompts_dir, "#{yielded_id}.response.json")
      File.write(response_path, JSON.generate({ "value" => "987654" }))
      result = thread.value
      assert_equal "987654", result

      # Request and response files cleaned up; .done breadcrumb left
      refute File.exist?(request_path)
      refute File.exist?(response_path)
      done_path = File.join(@prompts_dir, "#{yielded_id}.done")
      assert File.file?(done_path)
      done_payload = JSON.parse(File.read(done_path))
      assert_nil done_payload["value"], ".done must redact the value"
      assert done_payload["consumed_at"]
    end

    def test_confirm_kind_returns_true_on_response
      yielded_id = nil
      thread = Thread.new do
        store.prompt(kind: :confirm, message: "Approve on phone", timeout_seconds: 5) { |id, _r| yielded_id = id }
      end

      wait_for_request(yielded_id_proc: -> { yielded_id }, timeout: 2)
      File.write(File.join(@prompts_dir, "#{yielded_id}.response.json"), JSON.generate({ "confirmed" => true }))
      assert_equal true, thread.value
    end

    def test_timeout_raises
      store_obj = RemotePromptStore.new(prompts_dir: @prompts_dir)
      err = assert_raises(RemotePromptStore::Timeout) do
        store_obj.prompt(kind: :input, message: "Code?", timeout_seconds: 0)
      end
      assert_match(/timed out/, err.message)
    end

    def test_creates_prompts_dir_on_demand
      refute Dir.exist?(@prompts_dir)
      assert_raises(RemotePromptStore::Timeout) do
        store.prompt(kind: :input, message: "x", timeout_seconds: 0)
      end
      assert Dir.exist?(@prompts_dir)
    end

    def test_request_write_is_atomic
      # The write should never leave a partial .request.json visible — it
      # writes to .tmp first, then renames. Hard to observe directly here,
      # but we can at least confirm no .tmp files survive a successful write.
      yielded_id = nil
      thread = Thread.new do
        store.prompt(kind: :input, message: "x", timeout_seconds: 5) { |id, _| yielded_id = id }
      end
      wait_for_request(yielded_id_proc: -> { yielded_id }, timeout: 2)
      File.write(File.join(@prompts_dir, "#{yielded_id}.response.json"), JSON.generate({ "value" => "v" }))
      thread.value

      stragglers = Dir.children(@prompts_dir).select { |n| n.include?(".tmp.") }
      assert_empty stragglers, "no .tmp files should remain after a successful prompt round-trip"
    end

    private

    def wait_for_request(yielded_id_proc:, timeout:)
      deadline = Time.now + timeout
      until yielded_id_proc.call && File.exist?(File.join(@prompts_dir, "#{yielded_id_proc.call}.request.json"))
        sleep 0.05
        flunk "timed out waiting for prompt request file" if Time.now > deadline
      end
    end
  end
end
