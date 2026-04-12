# frozen_string_literal: true

require "io/console"

module Freentonic
  module Secrets
    # CLI secret backend: prompts the user interactively without persisting.
    #
    # Every run prompts again — there is no storage. Use this on CI or when
    # you want zero-trace secrets. Uses IO.console.noecho so the secret is
    # not echoed to the terminal, falling back to getpass when noecho is
    # unavailable (e.g. piped stdin).
    class Cli < Store
      def initialize(input: nil)
        @input = input
      end

      def fetch(source_key:, secret_name:)
        nil # ephemeral — never stored
      end

      def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
        stderr.print "#{prompt} (#{source_key}/#{secret_name}): "
        stderr.flush if stderr.respond_to?(:flush)

        value = read_secret
        raise UserError, "empty value provided for #{secret_name}" if value.nil? || value.empty?

        value
      end

      private

      def read_secret
        if @input
          @input.gets&.chomp
        elsif $stdin.tty? && $stdin.respond_to?(:noecho)
          result = $stdin.noecho(&:gets)
          $stderr.puts
          result&.chomp
        else
          $stdin.gets&.chomp
        end
      end
    end

    register(:cli, Cli)
  end
end
