# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

module Freentonic
  class SimplefinExporterTest < Minitest::Test
    def setup
      @root = Dir.mktmpdir("simplefin-exp-")
    end

    def teardown
      FileUtils.rm_rf(@root)
    end

    def sample
      {
        "accounts" => [
          {
            "external_id"   => "a1",
            "bank_name"     => "Acme",
            "currency"      => "EUR",
            "balance_cents" => 10_000,
            "balance_at"    => "2026-04-22T00:00:00Z",
            "movements"     => [
              { "dedup_key" => "t1", "amount_cents" => -100,
                "date" => "2026-04-20", "description" => "Test" }
            ]
          }
        ]
      }
    end

    def test_exporter_writes_reshaped_envelope
      exp = Exporters::Simplefin.new(profile_key: "test_profile", cache_root: @root)
      out = capture_stdout { exp.write(sample) }

      cache = Freentonic::Simplefin::Paths.cache_path("test_profile", @root)
      assert File.exist?(cache)
      payload = JSON.parse(File.read(cache))
      assert_equal 1, payload["accounts"].size
      assert_equal "a1", payload["accounts"].first["id"]
      assert_match(/wrote 1 account/, out)
    end

    def test_exporter_missing_profile_key_raises
      exp = Exporters::Simplefin.new({})
      # Avoid leaking the env var from the surrounding test process.
      original = ENV.delete("FREENTONIC_SIMPLEFIN_PROFILE_KEY")
      assert_raises(UserError) { exp.write(sample) }
    ensure
      ENV["FREENTONIC_SIMPLEFIN_PROFILE_KEY"] = original if original
    end

    def test_exporter_reads_env_fallback
      ENV["FREENTONIC_SIMPLEFIN_PROFILE_KEY"] = "from_env"
      exp = Exporters::Simplefin.new(cache_root: @root)
      capture_stdout { exp.write(sample) }
      assert File.exist?(Freentonic::Simplefin::Paths.cache_path("from_env", @root))
    ensure
      ENV.delete("FREENTONIC_SIMPLEFIN_PROFILE_KEY")
    end

    def test_exporter_rejects_bad_profile_key
      exp = Exporters::Simplefin.new(profile_key: "../escape", cache_root: @root)
      assert_raises(UserError) { exp.write(sample) }
    end

    def test_exporter_registered
      assert_includes Exporters.registered, :simplefin
    end

    private

    def capture_stdout
      original = $stdout
      $stdout  = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end
  end
end
