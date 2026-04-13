# frozen_string_literal: true

require "open3"
require "fileutils"
require "rbconfig"

module Freentonic
  # Removes all sensitive data freentonic created on the local machine:
  # Chrome profile, macOS Keychain entries, and leftover temp profiles.
  #
  # Export files at user-specified paths are NOT deleted — an advisory is
  # printed so the user can remove them manually.
  class Purge
    def initialize(stdout:, stderr:, stdin: $stdin, force: false,
                   chrome_profile_dir: ChromeCdp::DEFAULT_PROFILE_DIR,
                   temp_glob: "/tmp/freentonic-chrome-*")
      @stdout = stdout
      @stderr = stderr
      @stdin = stdin
      @force = force
      @chrome_profile_dir = chrome_profile_dir
      @temp_glob = temp_glob
    end

    def run
      artifacts = scan
      if artifacts.empty?
        @stdout.puts "Nothing to clean up."
        print_advisory
        return 0
      end

      print_summary(artifacts)

      unless @force
        return 1 unless confirm?
      end

      delete_chrome_profile!(artifacts)
      delete_temp_profiles!(artifacts)
      delete_keychain_entries!(artifacts) if macos?

      @stdout.puts "Done."
      print_advisory
      0
    end

    private

    def scan
      found = {}
      found[:chrome_profile] = @chrome_profile_dir if Dir.exist?(@chrome_profile_dir)
      temps = Dir.glob(@temp_glob).select { |p| File.directory?(p) }
      found[:temp_profiles] = temps unless temps.empty?
      if macos?
        entries = keychain_entries
        found[:keychain_entries] = entries unless entries.empty?
      end
      found
    end

    def print_summary(artifacts)
      @stdout.puts "The following freentonic data will be removed:\n\n"

      if artifacts[:chrome_profile]
        locked = chrome_profile_locked?
        @stdout.puts "  Chrome profile: #{@chrome_profile_dir}"
        @stdout.puts "    (!) Chrome may be using this profile — SingletonLock present" if locked
      end

      if artifacts[:temp_profiles]
        artifacts[:temp_profiles].each { |p| @stdout.puts "  Temp profile:   #{p}" }
      end

      if artifacts[:keychain_entries]
        artifacts[:keychain_entries].each do |entry|
          @stdout.puts "  Keychain entry: service=#{entry[:service]} account=#{entry[:account]}"
        end
      end

      @stdout.puts
    end

    def confirm?
      @stdout.print "Continue? [y/N] "
      @stdout.flush
      answer = @stdin.gets.to_s.strip
      answer.match?(/\Ay(es)?\z/i)
    end

    def delete_chrome_profile!(artifacts)
      return unless artifacts[:chrome_profile]

      if chrome_profile_locked? && !@force
        @stderr.puts "Skipping Chrome profile — SingletonLock present (use --force to override)"
        return
      end

      FileUtils.rm_rf(@chrome_profile_dir)
      @stdout.puts "Deleted Chrome profile: #{@chrome_profile_dir}"
    end

    def delete_temp_profiles!(artifacts)
      return unless artifacts[:temp_profiles]

      artifacts[:temp_profiles].each do |path|
        FileUtils.rm_rf(path)
        @stdout.puts "Deleted temp profile: #{path}"
      end
    end

    def delete_keychain_entries!(artifacts)
      return unless artifacts[:keychain_entries]

      artifacts[:keychain_entries].each do |entry|
        _out, err, status = Open3.capture3(
          "security", "delete-generic-password",
          "-s", entry[:service],
          "-a", entry[:account]
        )
        if status.success?
          @stdout.puts "Deleted keychain entry: service=#{entry[:service]} account=#{entry[:account]}"
        else
          @stderr.puts "Failed to delete keychain entry service=#{entry[:service]} account=#{entry[:account]}: #{err.strip}"
        end
      end
    end

    def keychain_entries
      out, _err, status = Open3.capture3("security", "dump-keychain")
      return [] unless status.success?

      parse_keychain_dump(out)
    end

    def parse_keychain_dump(output)
      entries = []
      current_service = nil
      current_account = nil

      output.each_line do |line|
        if line.include?("class:")
          # New entry block — flush previous if it matched
          if current_service&.start_with?("#{Secrets::MacosKeychain::SERVICE_PREFIX}.")
            entries << { service: current_service, account: current_account } if current_account
          end
          current_service = nil
          current_account = nil
        end

        if (match = line.match(/"svce"<blob>="([^"]*)"/))
          current_service = match[1]
        end

        if (match = line.match(/"acct"<blob>="([^"]*)"/))
          current_account = match[1]
        end
      end

      # Flush last entry
      if current_service&.start_with?("#{Secrets::MacosKeychain::SERVICE_PREFIX}.")
        entries << { service: current_service, account: current_account } if current_account
      end

      entries
    end

    def chrome_profile_locked?
      File.exist?(File.join(@chrome_profile_dir, "SingletonLock"))
    end

    def macos?
      RbConfig::CONFIG["host_os"].to_s.include?("darwin")
    end

    def print_advisory
      @stdout.puts
      @stdout.puts "Note: Export files (JSON, CSV, etc.) at user-specified paths are not"
      @stdout.puts "removed automatically. Delete those manually if they contain sensitive data."
      @stdout.puts "If you used --secrets plain_file, remove that file manually as well."
    end
  end
end
