# frozen_string_literal: true

require "time"

module Freentonic
  # Single source of truth for "coerce a value to a Unix millisecond
  # timestamp". Used by cursor pagination in ApiClient and by the provider
  # Helpers mixin — previously duplicated byte-for-byte in both.
  #
  #   TimestampMs.parse(1710504000000)               #=> 1710504000000
  #   TimestampMs.parse("2024-03-15T10:00:00.000Z")  #=> 1710504000000
  #   TimestampMs.parse(nil)                         #=> nil
  #
  # Numeric values already larger than 1e12 are assumed to be milliseconds
  # and passed through; smaller ones are treated as seconds and scaled.
  # Unparseable input returns nil rather than raising.
  module TimestampMs
    module_function

    def parse(value)
      case value
      when Numeric
        value > 1_000_000_000_000 ? value.to_i : (value * 1000).to_i
      when String
        if value =~ /\A\d+\z/
          v = value.to_i
          v > 1_000_000_000_000 ? v : v * 1000
        else
          (Time.parse(value).to_f * 1000).to_i
        end
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
