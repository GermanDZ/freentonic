# frozen_string_literal: true

module Freentonic
  module Normalizers
    # Builds the normalizer a workflow declares — Plan, provider Ruby, or
    # Passthrough — from its `normalize:` spec. Extracted from
    # Stages::Normalize so the same construction path is reachable outside a
    # full pipeline run: golden-parity tooling and per-provider parity tests
    # build the exact normalizer the workflow uses, so what they exercise is
    # what a live sync would run (no divergent test-only instantiation).
    module Builder
      module_function

      # @param spec [Hash, nil] the workflow's `normalize:` block
      # @param workflow_dir [String] dir the spec's relative ruby: resolves against
      def build(spec, workflow_dir:, stdout: $stdout, stderr: $stderr)
        return Passthrough.new if spec.nil?

        if spec.is_a?(Hash) && spec.key?("plan")
          config = Providers::Config.load_provider!(workflow_dir)
          return Plan.new(spec["plan"], config: config, stdout: stdout, stderr: stderr)
        end

        unless spec.is_a?(Hash) && spec["ruby"] && spec["class"]
          raise UserError, "normalize: must be a hash with ruby: and class: keys"
        end

        ruby_path = File.expand_path(spec["ruby"], workflow_dir)
        ruby_path = PathConfinement.resolve_within!(ruby_path, workflow_dir, label: "normalize.ruby")
        require ruby_path
        klass = spec["class"].to_s.split("::").inject(Object) { |ns, name| ns.const_get(name, false) }
        klass.new
      end

      # Convenience: load a workflow.yml and build its normalizer.
      def for_workflow(workflow_path, stdout: $stdout, stderr: $stderr)
        schema = WorkflowSchema.load(workflow_path)
        build(schema.normalizer, workflow_dir: File.dirname(workflow_path),
              stdout: stdout, stderr: stderr)
      end
    end
  end
end
