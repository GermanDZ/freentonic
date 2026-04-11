# frozen_string_literal: true

module Freentonic
  module Normalizers
    # Abstract base for normalizer plugins.
    #
    # A normalizer converts the raw output of the Extract stage into a
    # provider-agnostic structure suitable for exporters. Subclasses must
    # implement #call(raw, context:) and return a Hash or Array.
    #
    # Register declaratively via the workflow YAML:
    #
    #   normalize:
    #     ruby: ./normalizer.rb
    #     class: MyProvider::Normalizer
    #
    # The `ruby` path is resolved relative to the workflow YAML file.
    class Base
      def call(raw, context: {})
        raise NotImplementedError, "#{self.class} must implement #call"
      end
    end
  end
end
