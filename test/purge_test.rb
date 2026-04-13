# frozen_string_literal: true

require_relative "test_helper"
require "freentonic/purge"
require "tmpdir"
require "stringio"
require "fileutils"

module Freentonic
  class PurgeTest < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir("freentonic-purge-test")
      @chrome_dir = File.join(@tmpdir, "chrome")
      @temp_prefix = File.join(@tmpdir, "freentonic-chrome-")
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    # --- Force-mode tests (no confirmation prompt) ---

    def test_force_deletes_chrome_profile
      FileUtils.mkdir_p(@chrome_dir)
      File.write(File.join(@chrome_dir, "Cookies"), "fake")

      run_purge(force: true)

      refute Dir.exist?(@chrome_dir)
    end

    def test_force_deletes_temp_profiles
      temps = 2.times.map do |i|
        path = "#{@temp_prefix}#{i}"
        FileUtils.mkdir_p(path)
        path
      end

      run_purge(force: true)

      temps.each { |t| refute Dir.exist?(t), "#{t} should have been deleted" }
    end

    def test_deletes_keychain_entries
      skip "macOS only" unless macos?

      dump_output = <<~DUMP
        keychain: "/Users/test/Library/Keychains/login.keychain-db"
        version: 512
        class: "genp"
        attributes:
            "acct"<blob>="USER_PIN"
            "svce"<blob>="freentonic.example_bank"
        class: "genp"
        attributes:
            "acct"<blob>="USER_DNI"
            "svce"<blob>="freentonic.other_bank"
        class: "genp"
        attributes:
            "acct"<blob>="unrelated"
            "svce"<blob>="com.apple.something"
      DUMP

      deleted = []
      stdout, stderr = with_security_stubs(dump_output: dump_output, on_delete: ->(args) { deleted << args }) do
        run_purge(force: true)
      end

      assert_equal 2, deleted.size
      assert_includes deleted, { service: "freentonic.example_bank", account: "USER_PIN" }
      assert_includes deleted, { service: "freentonic.other_bank", account: "USER_DNI" }
      assert_includes stdout.string, "Deleted keychain entry: service=freentonic.example_bank"
    end

    def test_skips_keychain_on_non_macos
      original = RbConfig::CONFIG["host_os"]
      RbConfig::CONFIG["host_os"] = "linux-gnu"

      stdout, _stderr = run_purge(force: true, create_chrome: true)

      refute_includes stdout.string, "Keychain"
    ensure
      RbConfig::CONFIG["host_os"] = original
    end

    # --- Confirmation tests ---

    def test_confirmation_yes_proceeds
      FileUtils.mkdir_p(@chrome_dir)

      stdout, _stderr = run_purge(force: false, stdin_input: "y\n")

      refute Dir.exist?(@chrome_dir)
      assert_includes stdout.string, "Deleted Chrome profile"
    end

    def test_confirmation_no_aborts
      FileUtils.mkdir_p(@chrome_dir)

      result = run_purge(force: false, stdin_input: "n\n", return_exit_code: true)

      assert Dir.exist?(@chrome_dir), "Chrome profile should not have been deleted"
      assert_equal 1, result
    end

    def test_confirmation_empty_aborts
      FileUtils.mkdir_p(@chrome_dir)

      result = run_purge(force: false, stdin_input: "\n", return_exit_code: true)

      assert Dir.exist?(@chrome_dir)
      assert_equal 1, result
    end

    # --- Edge cases ---

    def test_nothing_to_clean
      stdout, _stderr = run_purge(force: true)

      assert_includes stdout.string, "Nothing to clean up."
    end

    def test_warns_about_locked_profile
      FileUtils.mkdir_p(@chrome_dir)
      File.write(File.join(@chrome_dir, "SingletonLock"), "")

      stdout, stderr = run_purge(force: false, stdin_input: "y\n")

      assert_includes stdout.string, "SingletonLock present"
      assert_includes stderr.string, "Skipping Chrome profile"
      assert Dir.exist?(@chrome_dir), "Locked profile should not be deleted without --force"
    end

    def test_force_deletes_locked_profile
      FileUtils.mkdir_p(@chrome_dir)
      File.write(File.join(@chrome_dir, "SingletonLock"), "")

      run_purge(force: true)

      refute Dir.exist?(@chrome_dir)
    end

    def test_prints_advisory_about_export_files
      stdout, _stderr = run_purge(force: true)

      assert_includes stdout.string, "Export files"
      assert_includes stdout.string, "--secrets plain_file"
    end

    def test_handles_keychain_delete_failure
      skip "macOS only" unless macos?

      dump_output = <<~DUMP
        class: "genp"
        attributes:
            "acct"<blob>="PIN"
            "svce"<blob>="freentonic.failing_bank"
      DUMP

      stdout, stderr = with_security_stubs(dump_output: dump_output, delete_fails: true) do
        run_purge(force: true)
      end

      assert_includes stderr.string, "Failed to delete keychain entry"
      assert_includes stdout.string, "Done."
    end

    def test_keychain_parser_skips_malformed_entries
      skip "macOS only" unless macos?

      dump_output = <<~DUMP
        class: "genp"
        attributes:
            "svce"<blob>="freentonic.good_bank"
            "acct"<blob>="PIN"
        class: "genp"
        attributes:
            "svce"<blob>="freentonic.no_account"
        class: "genp"
        attributes:
            garbage line
      DUMP

      deleted = []
      with_security_stubs(dump_output: dump_output, on_delete: ->(args) { deleted << args }) do
        run_purge(force: true)
      end

      assert_equal 1, deleted.size
      assert_equal "freentonic.good_bank", deleted[0][:service]
    end

    private

    def macos?
      RbConfig::CONFIG["host_os"].to_s.include?("darwin")
    end

    def run_purge(force: false, stdin_input: nil, create_chrome: false, return_exit_code: false)
      FileUtils.mkdir_p(@chrome_dir) if create_chrome

      stdout = StringIO.new
      stderr = StringIO.new
      stdin = StringIO.new(stdin_input || "")

      purge = Purge.new(
        stdout: stdout,
        stderr: stderr,
        stdin: stdin,
        force: force,
        chrome_profile_dir: @chrome_dir,
        temp_glob: "#{@temp_prefix}*"
      )

      # Stub keychain so tests that don't explicitly test keychain behavior
      # never scan or delete real Keychain entries.
      purge.define_singleton_method(:keychain_entries) { [] }

      code = purge.run
      return code if return_exit_code
      [stdout, stderr]
    end

    # Stubs Open3.capture3 for security commands used by the purge keychain logic.
    def with_security_stubs(dump_output:, on_delete: nil, delete_fails: false)
      stdout = nil
      stderr = nil
      original = Open3.method(:capture3)
      success_status = mock_status(true)
      failure_status = mock_status(false)
      Open3.define_singleton_method(:capture3) do |*args|
        if args[0] == "security" && args[1] == "dump-keychain"
          [dump_output, "", success_status]
        elsif args[0] == "security" && args[1] == "delete-generic-password"
          svc_idx = args.index("-s")
          acct_idx = args.index("-a")
          if on_delete && svc_idx && acct_idx
            on_delete.call({ service: args[svc_idx + 1], account: args[acct_idx + 1] })
          end
          if delete_fails
            ["", "security: SecKeychainSearchCopyNext: The specified item could not be found.", failure_status]
          else
            ["", "", success_status]
          end
        else
          original.call(*args)
        end
      end

      io_stdout = StringIO.new
      io_stderr = StringIO.new
      stdin = StringIO.new("")

      purge = Purge.new(
        stdout: io_stdout,
        stderr: io_stderr,
        stdin: stdin,
        force: true,
        chrome_profile_dir: @chrome_dir,
        temp_glob: "#{@temp_prefix}*"
      )
      purge.run

      [io_stdout, io_stderr]
    ensure
      Open3.define_singleton_method(:capture3, original) if original
    end

    # Minimal stand-in for Process::Status.
    def mock_status(success)
      obj = Object.new
      obj.define_singleton_method(:success?) { success }
      obj
    end
  end
end
