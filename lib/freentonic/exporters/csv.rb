# frozen_string_literal: true

require "csv"

module Freentonic
  module Exporters
    # Writes the payload as CSV. Behavior mirrors the JSONL exporter's
    # select-path semantics: options[:select] = "accounts.movements" flattens
    # the nested collection and emits one row per movement with parent
    # account fields hoisted as account_* columns.
    #
    # Column order: union of all row keys, sorted deterministically.
    # Options: { path:, select: }
    class Csv < Base
      def write(payload)
        rows = rows_for(payload)
        headers = rows.flat_map(&:keys).uniq.sort

        open_output(@options[:path]) do |io|
          csv = ::CSV.new(io)
          csv << headers
          rows.each { |row| csv << headers.map { |h| stringify(row[h]) } }
        end
      end

      private

      def rows_for(payload)
        if (path = @options[:select])
          flatten_select(payload, path.to_s.split("."))
        elsif payload.is_a?(Array)
          payload.map { |r| r.is_a?(Hash) ? r : { "value" => r } }
        else
          [payload.is_a?(Hash) ? payload : { "value" => payload }]
        end
      end

      def flatten_select(payload, path)
        return Array(payload) if path.empty?

        outer_key, *rest = path
        outer = payload.is_a?(Hash) ? Array(payload[outer_key]) : Array(payload)
        return outer if rest.empty?

        result = []
        outer.each do |parent|
          inner_key = rest.first
          children = Array(parent[inner_key])
          parent_prefix = outer_key.chomp("s")
          parent_fields = parent.reject { |k, _| k == inner_key }.transform_keys { |k| "#{parent_prefix}_#{k}" }
          children.each { |child| result << parent_fields.merge(child) }
        end
        result
      end

      def stringify(value)
        case value
        when nil    then ""
        when String then value
        when Hash, Array then ::JSON.generate(value)
        else value.to_s
        end
      end
    end

    register(:csv, Csv)
  end
end
