# frozen_string_literal: true

require "json"

module Freentonic
  module Exporters
    # Writes one JSON object per line. Behavior:
    #   - If the payload is an Array, each element becomes one line.
    #   - If the payload is a Hash and options[:select] names a nested path
    #     (e.g. "accounts.movements"), walks the path and emits one line per
    #     leaf item, with parent keys hoisted as "<parent>_<key>" columns.
    #   - Otherwise emits the whole payload as a single line.
    #
    # Options: { path:, select: "accounts.movements" }
    class Jsonl < Base
      def write(payload)
        lines = rows_for(payload).map { |row| ::JSON.generate(row) }
        open_output(@options[:path]) do |io|
          lines.each { |line| io.puts(line) }
        end
      end

      private

      def rows_for(payload)
        if (path = @options[:select])
          flatten_select(payload, path.to_s.split("."))
        elsif payload.is_a?(Array)
          payload
        else
          [payload]
        end
      end

      # Given ["accounts", "movements"] and a hash, yields each movement with
      # account_* fields merged in (excluding the "movements" key itself).
      def flatten_select(payload, path)
        return Array(payload) if path.empty?

        outer_key, *rest = path
        outer = payload.is_a?(Hash) ? Array(payload[outer_key]) : Array(payload)
        return outer if rest.empty?

        result = []
        outer.each do |parent|
          inner_key = rest.first
          children = Array(parent[inner_key])
          parent_prefix = outer_key.chomp("s") # accounts → account
          parent_fields = parent.reject { |k, _| k == inner_key }.transform_keys { |k| "#{parent_prefix}_#{k}" }
          children.each { |child| result << parent_fields.merge(child) }
        end
        result
      end
    end

    register(:jsonl, Jsonl)
  end
end
