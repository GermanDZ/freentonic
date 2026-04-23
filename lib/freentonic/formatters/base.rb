# frozen_string_literal: true

module Freentonic
  module Formatters
    # Abstract base for formatter plugins.
    #
    # A formatter takes a CanonicalPayload and returns a wire-shaped value:
    #
    #   - Hash / Array → caller (typically an exporter) JSON-encodes
    #   - String       → caller writes/POSTs the bytes as-is
    #
    # Formatters declare their content_type so the http exporter can set
    # the outgoing Content-Type header. The default is application/json
    # because most formatters return structured (Hash/Array) output;
    # override only for non-JSON formats (CSV, NDJSON, OFX, …).
    class Base
      def initialize(options = {})
        @options = options
      end

      def call(canonical_payload)
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      def content_type
        "application/json"
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
        unless klass
          raise UserError,
                "unknown format #{name.inspect} (available: #{registered.join(', ')})"
        end
        klass.new(options)
      end
    end
  end
end
