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

      # The invoke-server run directory, or nil for a local/CLI run.
      def run_dir
        dir = ENV["FREENTONIC_RUN_DIR"]
        dir if dir && !dir.empty?
      end

      # The operator prompt channel — non-nil only under the invoke server
      # (FREENTONIC_RUN_DIR set). Shared by the Extract and Elevate stages
      # to surface mid-flow prompts (SCA approval) the admin UI renders.
      def build_remote_prompt_store
        dir = run_dir
        return nil unless dir
        Freentonic::RemotePromptStore.new(
          prompts_dir: File.join(dir, "prompts"),
          announce_to: stderr
        )
      end
    end
  end
end
