# frozen_string_literal: true

require "open3"

module Freentonic
  module Secrets
    # macOS Keychain backend via the `security` CLI. Persists secrets in the
    # user's login keychain under service "freentonic.<source_key>" and
    # account "<secret_name>". First run launches an Apple-native prompt;
    # subsequent runs return silently.
    class MacosKeychain < Store
      SERVICE_PREFIX = "freentonic"

      def initialize(service_prefix: SERVICE_PREFIX)
        @service_prefix = service_prefix
      end

      def fetch(source_key:, secret_name:)
        stdout, _stderr, status = Open3.capture3(
          "security", "find-generic-password", "-w",
          "-a", account_name(secret_name),
          "-s", service_name(source_key)
        )
        return nil unless status.success?

        stdout.to_s.strip
      rescue Errno::ENOENT
        raise UserError, "macOS security CLI is not available — pass --secrets cli to prompt interactively"
      end

      def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
        stdout.puts "  Secret #{secret_name} is not stored yet."
        stdout.puts "  It will be saved in your macOS Keychain for reuse."
        stdout.puts "  Prompt: #{prompt}"

        ok = system(
          "security", "add-generic-password", "-U",
          "-a", account_name(secret_name),
          "-s", service_name(source_key),
          "-j", prompt,
          "-w"
        )

        raise UserError, "failed to store #{secret_name} in macOS Keychain" unless ok

        value = fetch(source_key: source_key, secret_name: secret_name)
        raise UserError, "stored #{secret_name} but could not read it back from macOS Keychain" if value.nil? || value.empty?

        value
      end

      private

      def service_name(source_key)
        "#{@service_prefix}.#{source_key}"
      end

      def account_name(secret_name)
        secret_name.to_s
      end
    end

    register(:macos_keychain, MacosKeychain)
  end
end
