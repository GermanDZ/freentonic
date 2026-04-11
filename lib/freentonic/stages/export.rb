# frozen_string_literal: true

module Freentonic
  module Stages
    # Export stage: fans the normalized payload out to every exporter the
    # CLI assembled. Exporters are passed in via context[:exporters] as an
    # array of already-constructed Exporters::Base instances.
    #
    # Non-fatal exporter errors are collected and re-raised after all
    # exporters have had a chance to run, so a failing HTTP push doesn't
    # prevent a local JSON dump (or vice versa).
    class Export < Base
      def call
        payload = @context.fetch(:normalized) do
          raise UserError, "export stage: no normalized payload in context (run normalize first or pass --from-normalized)"
        end

        exporters = Array(@context[:exporters])
        raise UserError, "no exporters configured — pass --export NAME at least once" if exporters.empty?

        errors = []
        results = exporters.map do |exporter|
          stdout.puts "\nExporting via #{exporter.class.name.split("::").last.downcase}..."
          begin
            exporter.write(payload)
          rescue ExportError => e
            stderr.puts "  ✗ #{e.message}"
            errors << e
            nil
          end
        end

        raise errors.first if errors.any?

        @context[:export_results] = results
        @context
      end
    end
  end
end
