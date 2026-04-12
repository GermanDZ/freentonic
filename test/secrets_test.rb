# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"
require "stringio"

module Freentonic
  class SecretsTest < Minitest::Test
    def test_cli_backend_prompts_and_returns_value
      input = StringIO.new("hunter2\n")
      stderr = StringIO.new
      backend = Secrets::Cli.new(input: input)

      assert_nil backend.fetch(source_key: "ing", secret_name: "PIN")
      value = backend.prompt_and_store(
        source_key: "ing", secret_name: "PIN", prompt: "Enter PIN",
        stdout: StringIO.new, stderr: stderr
      )
      assert_equal "hunter2", value
      assert_includes stderr.string, "Enter PIN"
    end

    def test_cli_backend_raises_when_value_is_empty
      input = StringIO.new("\n")
      backend = Secrets::Cli.new(input: input)
      assert_raises(UserError) do
        backend.prompt_and_store(
          source_key: "ing", secret_name: "PIN", prompt: "Enter PIN",
          stdout: StringIO.new, stderr: StringIO.new
        )
      end
    end

    def test_plain_file_rejects_world_readable_file
      Tempfile.open("freentonic-secrets") do |tmp|
        tmp.write("ing.PIN=1234\n")
        tmp.flush
        File.chmod(0o644, tmp.path)
        assert_raises(UserError) { Secrets::PlainFile.new(path: tmp.path) }
      end
    end

    def test_plain_file_reads_scoped_and_bare_keys
      Tempfile.open("freentonic-secrets") do |tmp|
        tmp.write("ing.PIN=1234\nOTHER=xyz\n# comment\n")
        tmp.flush
        File.chmod(0o600, tmp.path)

        backend = Secrets::PlainFile.new(path: tmp.path)
        assert_equal "1234", backend.fetch(source_key: "ing",  secret_name: "PIN")
        assert_equal "xyz",  backend.fetch(source_key: "other", secret_name: "OTHER")
      end
    end

    def test_secrets_registry_builds_known_backends
      assert_includes Secrets.registered, :cli
      assert_includes Secrets.registered, :macos_keychain
      assert_includes Secrets.registered, :plain_file

      assert_raises(UserError) { Secrets.build(:does_not_exist) }
    end
  end
end
