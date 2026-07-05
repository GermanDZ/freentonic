# frozen_string_literal: true

module Freentonic
  module Stages
    # Export stage: fans the normalized payload out to every exporter the
    # CLI assembled. Exporters are passed in via context[:exporters] as an
    # array of already-constructed Exporters::Base instances.
    #
    # Non-fatal exporter errors are collected and re-raised after all
    # exporters have had a chance to run, so a failing HTTP push doesn't
    # prevent a local JSON dump (or vice versa). A single failure re-raises
    # verbatim; multiple failures raise one aggregate error naming every
    # exporter that failed (rather than silently dropping all but the first).
    class Export < Base
      def call
        payload = @context.fetch(:normalized) do
          raise UserError, "export stage: no normalized payload in context (run normalize first or pass --from-normalized)"
        end

        exporters = Array(@context[:exporters])
        raise UserError, "no exporters configured — pass --export NAME at least once" if exporters.empty?

        errors = []
        results = exporters.map do |exporter|
          name = exporter_name(exporter)
          # Route the exporter's own progress output through the engine's
          # injected stream rather than global $stdout.
          exporter.io = stdout if exporter.respond_to?(:io=)
          stdout.puts "\nExporting via #{name}..."
          begin
            exporter.write(payload)
          rescue ExportError => e
            stderr.puts "  ✗ #{e.message}"
            errors << [name, e]
            nil
          end
        end

        raise aggregate_error(errors) if errors.any?

        @context[:export_results] = results
        @context
      end

      private

      def exporter_name(exporter)
        exporter.class.name.split("::").last.downcase
      end

      # One failure → re-raise it verbatim (preserves message + class).
      # Several → a single ExportError that names each failed exporter, so
      # no failure is lost to the caller.
      def aggregate_error(errors)
        return errors.first.last if errors.one?

        names = errors.map(&:first).join(", ")
        detail = errors.map { |name, e| "  - #{name}: #{e.message}" }.join("\n")
        ExportError.new("#{errors.size} exporters failed (#{names}):\n#{detail}")
      end
    end
  end
end
