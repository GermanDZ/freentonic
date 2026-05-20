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
      assert_includes Secrets.registered, :inline_fd

      assert_raises(UserError) { Secrets.build(:does_not_exist) }
    end

    def test_inline_fd_reads_dotenv_payload_and_closes_fd
      read_io, write_io = IO.pipe
      write_io.write("ing.PIN=1234\nOTHER=xyz\n# comment\n\n")
      write_io.close

      backend = Secrets::InlineFd.new(fd: read_io.fileno)

      assert_equal "1234", backend.fetch(source_key: "ing",   secret_name: "PIN")
      assert_equal "xyz",  backend.fetch(source_key: "other", secret_name: "OTHER")
      assert_nil backend.fetch(source_key: "ing", secret_name: "MISSING")

      # The backend must have closed the fd after consuming the payload.
      # Reading from the underlying fileno should fail with EBADF.
      assert_raises(Errno::EBADF) { IO.for_fd(read_io.fileno, "r").read }
    ensure
      write_io.close if write_io && !write_io.closed?
      # read_io was wrapped + closed inside the backend; nothing to do here.
    end

    def test_inline_fd_strips_surrounding_quotes_like_plain_file
      read_io, write_io = IO.pipe
      write_io.write(%(ing.PIN="hunter2"\n))
      write_io.close

      backend = Secrets::InlineFd.new(fd: read_io.fileno)
      assert_equal "hunter2", backend.fetch(source_key: "ing", secret_name: "PIN")
    end

    def test_inline_fd_raises_on_prompt
      read_io, write_io = IO.pipe
      write_io.close
      backend = Secrets::InlineFd.new(fd: read_io.fileno)

      err = assert_raises(UserError) do
        backend.prompt_and_store(
          source_key: "ing", secret_name: "PIN", prompt: "Enter PIN",
          stdout: StringIO.new, stderr: StringIO.new
        )
      end
      assert_match(/inline_fd backend cannot prompt/, err.message)
      assert_match(/ing\.PIN/, err.message)
    end
  end
end
