# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"
require "stringio"
require "json"

module Freentonic
  class CliTest < Minitest::Test
    # Exercises the stage-isolation path: --from-raw feeds a pre-captured raw
    # payload into the pipeline, skipping Connect + Extract entirely, and
    # --export json with a Passthrough normalizer (no normalize: block in the
    # fixture workflow) round-trips the payload to disk.
    def test_from_raw_skips_chrome_and_exports_via_json
      workflow_yaml = <<~YAML
        version: 1
        config:
          key: fixture
          default_lookback_days: 1
        pipeline: []
        phases: {}
        secrets: {}
        credentials:
          map: []
      YAML

      raw_payload = { "source_tag" => "fixture", "rows" => [{ "id" => 1 }, { "id" => 2 }] }

      Dir.mktmpdir("freentonic-cli") do |dir|
        workflow_path = File.join(dir, "workflow.yml")
        raw_path      = File.join(dir, "raw.json")
        out_path      = File.join(dir, "out.json")
        File.write(workflow_path, workflow_yaml)
        File.write(raw_path, ::JSON.generate(raw_payload))

        stdout = StringIO.new
        stderr = StringIO.new
        status = Cli.new(stdout: stdout, stderr: stderr).run([
          "--workflow", workflow_path,
          "--from-raw", raw_path,
          "--export", "json",
          "--export-path", out_path
        ])

        assert_equal 0, status, stderr.string
        assert File.exist?(out_path), "exporter did not write #{out_path}"
        assert_equal raw_payload, ::JSON.parse(File.read(out_path))
      end
    end

    def test_missing_workflow_returns_error
      stderr = StringIO.new
      status = Cli.new(stdout: StringIO.new, stderr: stderr).run([])
      assert_equal 1, status
      assert_includes stderr.string, "missing --workflow"
    end

    def test_purge_rejects_workflow_flag
      stderr = StringIO.new
      status = Cli.new(stdout: StringIO.new, stderr: stderr).run(["--purge", "--workflow", "x.yml"])
      assert_equal 1, status
      assert_includes stderr.string, "--purge cannot be combined with --workflow"
    end

    def test_purge_rejects_export_flag
      stderr = StringIO.new
      status = Cli.new(stdout: StringIO.new, stderr: stderr).run(["--purge", "--export", "json"])
      assert_equal 1, status
      assert_includes stderr.string, "--export cannot be combined with --purge"
    end

    def test_force_without_purge_rejects
      stderr = StringIO.new
      status = Cli.new(stdout: StringIO.new, stderr: stderr).run([
        "--force", "--workflow", "x.yml", "--export", "json", "--export-path", "x"
      ])
      assert_equal 1, status
      assert_includes stderr.string, "--force is only valid with --purge"
    end

    def test_purge_rejects_from_raw
      stderr = StringIO.new
      status = Cli.new(stdout: StringIO.new, stderr: stderr).run(["--purge", "--from-raw", "x.json"])
      assert_equal 1, status
      assert_includes stderr.string, "--purge cannot be combined with --from-raw"
    end
  end
end
