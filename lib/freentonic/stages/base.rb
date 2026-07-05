# frozen_string_literal: true

module Freentonic
  module Stages
    # Abstract base for pipeline stages. Stages share a mutable `context`
    # Hash and each one either reads from it, writes to it, or produces a
    # terminal effect (Export).
    #
    # The context is passed to #initialize once per Engine#run. Subclasses
    # implement #call which should return the context (or the stage's
    # output) for chaining.
    class Base
      attr_reader :context

      def initialize(context:)
        @context = context
      end

      def call
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      protected

      def stdout
        @context[:stdout] || $stdout
      end

      def stderr
        @context[:stderr] || $stderr
      end

      def reporter
        @context[:reporter] || Reporter.null
      end

      def source
        @context.fetch(:source)
      end

      def schema
        source.workflow
      end
    end
  end
end
