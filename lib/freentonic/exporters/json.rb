# frozen_string_literal: true

require "json"

module Freentonic
  module Exporters
    # Writes the payload as pretty-printed JSON. Options:
    #   path:   "out.json" or "-"/nil for stdout
    #   format: formatter name (default :canonical)
    #
    # When the resolved formatter returns a Hash/Array, output is
    # JSON.pretty_generate'd. When it returns a String (e.g., a future OFX
    # formatter routed through --export json out of stubbornness), it is
    # written verbatim — the caller chose the path/extension.
    class Json < Base
      def write(payload)
        formatter = resolve_formatter
        output = formatter.call(payload)
        body = case output
               when String then output
               else ::JSON.pretty_generate(output)
               end

        open_output(@options[:path]) do |io|
          io.write(body)
          io.write("\n") unless @options[:path].nil? || @options[:path] == "-" || body.end_with?("\n")
        end
      end
    end

    register(:json, Json)
  end
end
