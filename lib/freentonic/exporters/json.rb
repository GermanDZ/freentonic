# frozen_string_literal: true

require "json"

module Freentonic
  module Exporters
    # Writes the payload as pretty-printed JSON.
    #
    # Options:
    #   path: "out.json" or "-"/nil for stdout
    #
    # Accepts either a CanonicalPayload (calls `to_h` for the wire shape)
    # or a plain Hash (passed through — `Hash#to_h` returns self).
    class Json < Base
      def write(payload)
        body = ::JSON.pretty_generate(payload.to_h)

        open_output(@options[:path]) do |io|
          io.write(body)
          io.write("\n") unless @options[:path].nil? || @options[:path] == "-" || body.end_with?("\n")
        end
      end
    end

    register(:json, Json)
  end
end
