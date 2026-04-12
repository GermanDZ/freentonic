# frozen_string_literal: true

require "date"

module Freentonic
  module Stages
    # Extract stage: uses the workflow's api_client config and a provider-
    # supplied Extractor class to turn captured credentials into a raw
    # provider-shape payload.
    #
    # Reads context[:credentials], writes context[:raw].
    #
    # Extractor contract: the workflow YAML declares
    #
    #   extract:
    #     ruby: ./extractor.rb
    #     class: MyProvider::Extractor
    #
    # Extractor classes must implement #call(client:, credentials:, from_date:, stdout:, stderr:)
    # and return the raw provider payload (a Hash or Array).
    class Extract < Base
      def call
        stdout.puts "\nFetching data..."
        from_date = Date.today - @context.fetch(:lookback_days)

        client = source.workflow.build_api_client(@context[:credentials])
        extractor = load_extractor

        @context[:raw] = extractor.call(
          client: client,
          credentials: @context[:credentials],
          from_date: from_date,
          stdout: stdout,
          stderr: stderr
        )
        @context
      end

      private

      def load_extractor
        spec = source.workflow.config["extract"] || source.extract_spec
        unless spec.is_a?(Hash) && spec["ruby"] && spec["class"]
          raise UserError, "workflow #{source.workflow.path}: extract: must be a hash with ruby: and class: keys"
        end

        ruby_path = File.expand_path(spec["ruby"], File.dirname(source.workflow.path))
        require ruby_path
        klass = spec["class"].to_s.split("::").inject(Object) { |ns, name| ns.const_get(name, false) }
        klass.new
      end
    end
  end
end
