# frozen_string_literal: true

require "json"

module Freentonic
  module Exporters
    # Writes the payload as pretty-printed JSON. Options: { path: "out.json" }
    # or path: "-" / nil for stdout.
    class Json < Base
      def write(payload)
        open_output(@options[:path]) do |io|
          io.write(::JSON.pretty_generate(payload))
          io.write("\n") unless @options[:path].nil? || @options[:path] == "-"
        end
      end
    end

    register(:json, Json)
  end
end
