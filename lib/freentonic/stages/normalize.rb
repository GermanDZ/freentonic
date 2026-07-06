# frozen_string_literal: true

module Freentonic
  module Stages
    # Normalize stage: applies the workflow's declared normalizer to
    # context[:raw], producing context[:normalized].
    #
    # If the workflow declares no `normalize:` block, falls back to the
    # Passthrough identity normalizer. The ruby file is required relative to
    # the workflow YAML's directory so providers can ship code alongside
    # their YAML.
    class Normalize < Base
      def call
        raw = @context.fetch(:raw) do
          raise UserError, "normalize stage: no raw payload in context (run extract first or pass --from-raw)"
        end

        stdout.puts "\nNormalizing payload..."
        normalizer = load_normalizer
        @context[:normalized] = normalizer.call(raw, context: @context)
        @context
      end

      private

      def load_normalizer
        Normalizers::Builder.build(schema.normalizer,
                                   workflow_dir: File.dirname(schema.path),
                                   stdout: stdout, stderr: stderr)
      rescue UserError => e
        # Preserve the workflow-scoped message the stage used to emit.
        raise UserError, "workflow #{schema.path}: #{e.message}"
      end
    end
  end
end
