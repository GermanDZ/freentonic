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
      # Progress/status stream. Defaults to $stdout so exporters work
      # standalone, but the Export stage overwrites it with the engine's
      # injected stream so status lines land in the run log (and are
      # capturable in tests) like every other stage's output. Data output
      # (the actual export destination for path=nil/"-") still uses
      # #open_output → $stdout; only human progress lines go through #io.
      attr_accessor :io

      def initialize(options = {})
        @options = options
        @io = options[:io] || $stdout
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
