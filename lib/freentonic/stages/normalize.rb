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
        spec = schema.normalizer
        return Normalizers::Passthrough.new if spec.nil?

        unless spec.is_a?(Hash) && spec["ruby"] && spec["class"]
          raise UserError, "workflow #{schema.path}: normalize: must be a hash with ruby: and class: keys"
        end

        ruby_path = File.expand_path(spec["ruby"], File.dirname(schema.path))
        require ruby_path
        klass = spec["class"].to_s.split("::").inject(Object) { |ns, name| ns.const_get(name, false) }
        klass.new
      end
    end
  end
end
