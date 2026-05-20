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

    def test_no_sandbox_flag_is_accepted
      stderr = StringIO.new
      status = Cli.new(stdout: StringIO.new, stderr: stderr).run(["--no-sandbox"])
      assert_equal 1, status
      assert_includes stderr.string, "missing --workflow"
      refute_includes stderr.string, "invalid option"
    end

    def test_invalid_option_returns_error
      stderr = StringIO.new
      status = Cli.new(stdout: StringIO.new, stderr: stderr).run(["--headless-disable"])
      assert_equal 1, status
      assert_includes stderr.string, "invalid option: --headless-disable"
    end

    def test_purge_rejects_from_raw
      stderr = StringIO.new
      status = Cli.new(stdout: StringIO.new, stderr: stderr).run(["--purge", "--from-raw", "x.json"])
      assert_equal 1, status
      assert_includes stderr.string, "--purge cannot be combined with --from-raw"
    end

    # --- Stage isolation: --through connect / --through extract -----------
    # Both should accept runs without --export, since the pipeline stops
    # before the Export stage runs (matching --only-stage connect/extract).

    def test_through_connect_accepts_runs_without_exporter
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--through", "connect"])
      Cli.new(stderr: StringIO.new).send(:validate!, opts)
    end

    def test_through_extract_accepts_runs_without_exporter
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--through", "extract"])
      Cli.new(stderr: StringIO.new).send(:validate!, opts)
    end

    def test_through_normalize_still_requires_exporter
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--through", "normalize"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/no exporters configured/, err.message)
    end

    def test_run_without_exporter_or_stage_isolation_still_rejected
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/no exporters configured/, err.message)
    end

    # --- Interactive (browse) mode --------------------------------------
    # `--interactive` forces the engine to run only Connect, so combining
    # it with stage-isolation or serialized-input flags either contradicts
    # that intent or yields an empty pipeline. Reject up-front.

    def test_interactive_accepts_runs_without_exporter
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--interactive"])
      Cli.new(stderr: StringIO.new).send(:validate!, opts)
    end

    def test_interactive_rejects_only_stage
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--interactive", "--only-stage", "extract"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/--interactive cannot be combined with --only-stage/, err.message)
    end

    def test_interactive_rejects_through
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--interactive", "--through", "extract"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/--interactive cannot be combined with --through/, err.message)
    end

    def test_interactive_rejects_from_raw
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--interactive", "--from-raw", "/tmp/raw.json"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/--interactive cannot be combined with --from-raw/, err.message)
    end

    def test_interactive_rejects_from_normalized
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--interactive", "--from-normalized", "/tmp/n.json"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/--interactive cannot be combined with --from-normalized/, err.message)
    end

    def test_interactive_rejects_dump_raw
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--interactive", "--dump-raw", "/tmp/raw.json"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/--interactive cannot be combined with --dump-raw/, err.message)
    end

    def test_interactive_rejects_dump_normalized
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--interactive", "--dump-normalized", "/tmp/n.json"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/--interactive cannot be combined with --dump-normalized/, err.message)
    end

    # --- Secret-backend option matrix --------------------------------------

    def secret_options(overrides = {})
      {
        secrets_backend: nil,
        secrets_file: nil,
        secrets_fd: nil
      }.merge(overrides)
    end

    def test_inline_fd_without_secrets_fd_rejects
      cli = Cli.new(stderr: StringIO.new)
      err = assert_raises(UserError) do
        cli.send(:build_secret_store, secret_options(secrets_backend: :inline_fd))
      end
      assert_match(/inline_fd requires --secrets-fd/, err.message)
    end

    def test_inline_fd_with_secrets_file_rejects
      cli = Cli.new(stderr: StringIO.new)
      err = assert_raises(UserError) do
        cli.send(:build_secret_store, secret_options(
          secrets_backend: :inline_fd, secrets_fd: 3, secrets_file: "/tmp/x"
        ))
      end
      assert_match(/inline_fd does not take --secrets-file/, err.message)
    end

    def test_plain_file_with_secrets_fd_rejects
      # Same "--secrets-fd requires --secrets inline_fd" rule — there is no
      # combination of plain_file + --secrets-fd that's meaningful.
      cli = Cli.new(stderr: StringIO.new)
      err = assert_raises(UserError) do
        cli.send(:build_secret_store, secret_options(
          secrets_backend: :plain_file, secrets_file: "/tmp/x", secrets_fd: 3
        ))
      end
      assert_match(/--secrets-fd requires --secrets inline_fd/, err.message)
    end

    def test_secrets_fd_without_inline_fd_backend_rejects
      cli = Cli.new(stderr: StringIO.new)
      err = assert_raises(UserError) do
        # backend left as nil, so Secrets.default_name kicks in (cli or
        # macos_keychain depending on host). Either way, --secrets-fd is
        # only valid alongside --secrets inline_fd.
        cli.send(:build_secret_store, secret_options(secrets_fd: 3))
      end
      assert_match(/--secrets-fd requires --secrets inline_fd/, err.message)
    end

    def test_interactive_rejects_export
      # Output-producing exporters can never fire on the interactive path
      # (engine short-circuits at Connect). Reject explicitly so the
      # operator notices instead of getting a "successful" run with
      # nothing exported.
      opts = Cli.new(stderr: StringIO.new).send(:parse, ["--workflow", "x.yml", "--interactive", "--export", "json", "--export-path", "out.json"])
      err = assert_raises(UserError) { Cli.new(stderr: StringIO.new).send(:validate!, opts) }
      assert_match(/--interactive cannot be combined with --export/, err.message)
    end
  end
end
