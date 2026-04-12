# frozen_string_literal: true

require "rbconfig"

module Freentonic
  module Secrets
    # Abstract base class for secret backends.
    #
    # Subclasses must implement:
    #
    #   fetch(source_key:, secret_name:)
    #     Returns the stored value as a String, or nil if not stored.
    #
    #   prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
    #     Prompts the user for the value and optionally persists it. Returns
    #     the value as a String. MUST NOT return nil.
    #
    # Register a custom backend via `Freentonic::Secrets.register(:name, MyClass)`.
    class Store
      def fetch(source_key:, secret_name:)
        raise NotImplementedError, "#{self.class} must implement #fetch"
      end

      def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
        raise NotImplementedError, "#{self.class} must implement #prompt_and_store"
      end
    end

    @registry = {}

    class << self
      def register(name, klass)
        @registry[name.to_sym] = klass
      end

      def registered
        @registry.keys.sort
      end

      def build(name, **opts)
        klass = @registry[name.to_sym]
        raise UserError, "unknown secret backend #{name.inspect} (available: #{registered.join(", ")})" unless klass
        klass.new(**opts)
      end

      # Default backend based on host OS. macOS → Keychain, otherwise CLI prompt.
      def default_name
        return :macos_keychain if RbConfig::CONFIG["host_os"].to_s.include?("darwin")
        :cli
      end
    end
  end
end
