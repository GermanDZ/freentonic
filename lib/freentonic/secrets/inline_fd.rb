# frozen_string_literal: true

module Freentonic
  module Secrets
    # In-process dotenv backend. The parent process passes the dotenv payload
    # through an inherited pipe; this backend reads it from the given fd on
    # construction, parses it, and closes the fd. Nothing is materialized to
    # disk. Used by InvokeRunner for `/invoke` requests carrying inline
    # credentials.
    #
    # File format matches PlainFile: one KEY=VALUE pair per line, where KEY is
    # "<source_key>.<secret_name>" or a bare "<secret_name>". Blank lines and
    # `#` comments are ignored.
    class InlineFd < Store
      def initialize(fd:)
        @values = read_dotenv_from_fd(fd)
      end

      def fetch(source_key:, secret_name:)
        scoped = "#{source_key}.#{secret_name}"
        @values[scoped] || @values[secret_name.to_s]
      end

      def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
        raise UserError,
              "inline_fd backend cannot prompt — caller must include " \
              "'#{source_key}.#{secret_name}=...' in the inline payload " \
              "(prompt: #{prompt})"
      end

      private

      def read_dotenv_from_fd(fd)
        io = IO.for_fd(Integer(fd), "r")
        result = {}
        io.each_line do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")
          key, val = line.split("=", 2)
          next unless key && val
          result[key.strip] = val.strip.gsub(/\A"(.*)"\z/, '\1')
        end
        result
      ensure
        io&.close
      end
    end

    register(:inline_fd, InlineFd)
  end
end
