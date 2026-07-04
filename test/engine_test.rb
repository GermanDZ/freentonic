# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "json"

module Freentonic
  # Focused coverage for Engine's offline-replay input loading. The rest of the
  # pipeline is exercised through the stage tests and the example integration
  # test; here we only pin that a bad --from-raw / --from-normalized path
  # becomes a clean UserError instead of an uncaught Errno / JSON backtrace.
  class EngineTest < Minitest::Test
    def load_inputs(context)
      Engine.new(context: context).send(:load_serialized_inputs!)
    end

    def test_from_raw_malformed_json_is_user_error
      Dir.mktmpdir do |d|
        path = File.join(d, "raw.json")
        File.write(path, "{ this is not json")
        err = assert_raises(UserError) { load_inputs(from_raw: path) }
        assert_includes err.message, "--from-raw"
        assert_includes err.message, "not valid JSON"
      end
    end

    def test_from_raw_missing_file_is_user_error
      err = assert_raises(UserError) { load_inputs(from_raw: "/no/such/raw.json") }
      assert_includes err.message, "--from-raw"
      assert_includes err.message, "file not found"
    end

    def test_from_normalized_malformed_json_is_user_error
      Dir.mktmpdir do |d|
        path = File.join(d, "normalized.json")
        File.write(path, "not json at all")
        err = assert_raises(UserError) { load_inputs(from_normalized: path) }
        assert_includes err.message, "--from-normalized"
      end
    end

    def test_valid_from_raw_loads_into_context
      Dir.mktmpdir do |d|
        path = File.join(d, "raw.json")
        File.write(path, JSON.generate("accounts" => []))
        context = { from_raw: path }
        Engine.new(context: context).send(:load_serialized_inputs!)
        assert_equal({ "accounts" => [] }, context[:raw])
      end
    end
  end
end
