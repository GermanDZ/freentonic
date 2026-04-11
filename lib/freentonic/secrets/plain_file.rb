# frozen_string_literal: true

module Freentonic
  module Secrets
    # Plain-file (dotenv) backend. INSECURE by design — use only for CI or
    # trusted dev boxes. Refuses to load a file whose mode is readable by
    # group or other (mode & 0o077 must be zero).
    #
    # File format: one KEY=VALUE pair per line. KEY is "<source_key>.<secret_name>"
    # (matching the prompt), or bare "<secret_name>" as a fallback. Blank
    # lines and lines starting with `#` are ignored.
    #
    # The CLI emits an INSECURE banner every invocation this backend is used.
    class PlainFile < Store
      def initialize(path:)
        @path = File.expand_path(path)
        validate_permissions!
        @values = load_file
      end

      def fetch(source_key:, secret_name:)
        scoped = "#{source_key}.#{secret_name}"
        @values[scoped] || @values[secret_name.to_s]
      end

      def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
        raise UserError,
              "plain_file backend cannot prompt — add '#{source_key}.#{secret_name}=...' " \
              "to #{@path} and re-run (prompt: #{prompt})"
      end

      def self.insecure_banner
        "⚠️  Freentonic is using the INSECURE plain_file secret backend. Secrets are stored " \
          "in plaintext. Rotate secrets stored this way and prefer a real backend in production."
      end

      private

      def validate_permissions!
        raise UserError, "plain_file secrets: #{@path} does not exist" unless File.exist?(@path)

        mode = File.stat(@path).mode & 0o777
        if (mode & 0o077) != 0
          raise UserError,
                "plain_file secrets: #{@path} has permissive mode #{mode.to_s(8).rjust(3, "0")} — " \
                "run `chmod 600 #{@path}` so only you can read it"
        end
      end

      def load_file
        result = {}
        File.foreach(@path) do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")
          key, val = line.split("=", 2)
          next unless key && val
          result[key.strip] = val.strip.gsub(/\A"(.*)"\z/, '\1')
        end
        result
      end
    end

    register(:plain_file, PlainFile)
  end
end
