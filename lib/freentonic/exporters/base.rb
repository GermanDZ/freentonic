# frozen_string_literal: true

module Freentonic
  module Exporters
    # Abstract base class for exporter plugins.
    #
    # Subclasses receive their CLI-assembled options hash via #initialize
    # and must implement #write(payload). A single freentonic invocation may
    # instantiate any number of exporters — each --export flag creates a new
    # instance and subsequent --export-* flags attach to the most recently
    # declared one.
    class Base
      def initialize(options = {})
        @options = options
      end

      def write(payload)
        raise NotImplementedError, "#{self.class} must implement #write"
      end

      protected

      # Helper for file-or-stdout writing. Yields an IO; caller writes to it.
      # path = nil or "-" means stdout.
      def open_output(path, &block)
        return block.call($stdout) if path.nil? || path == "-"
        File.open(path, "w", &block)
      end

      # Build the formatter selected by --export-format, or this exporter's
      # default if none was given. Subclasses opt into formatter-driven
      # output by calling this in #write; csv/jsonl ignore it until PR 4
      # rewrites them.
      def resolve_formatter
        Formatters.build(@options[:format] || default_format)
      end

      # Per-exporter default format. Subclasses override; Base returns
      # :canonical because the canonical formatter is the identity on the
      # legacy Hash payloads existing tests pass, so behavior is preserved
      # automatically.
      def default_format
        :canonical
      end
    end

    @registry = {}

    class << self
      def register(name, klass)
        @registry[name.to_sym] = klass
      end

      def registered
        @registry.keys.sort
      end

      def build(name, options = {})
        klass = @registry[name.to_sym]
        raise UserError, "unknown exporter #{name.inspect} (available: #{registered.join(", ")})" unless klass
        klass.new(options)
      end
    end
  end
end
