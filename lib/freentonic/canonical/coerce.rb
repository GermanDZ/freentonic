# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

module Freentonic
  module Canonical
    # Shared type-coercion helpers used by entity factories and wire
    # serialization. Keeps BigDecimal/Date/Time logic in one place so every
    # entity agrees on what an input string turns into and what wire output
    # looks like.
    module Coerce
      module_function

      # String | Numeric | BigDecimal | nil → BigDecimal | nil.
      def amount(value)
        case value
        when nil        then nil
        when BigDecimal then value
        when Integer    then BigDecimal(value)
        when Float      then BigDecimal(value.to_s)
        when String
          return nil if value.strip.empty?
          BigDecimal(value)
        else
          raise UserError, "canonical: cannot coerce #{value.inspect} to BigDecimal amount"
        end
      end

      # BigDecimal | nil → String | nil. Fixed-point, no scientific notation.
      def amount_to_wire(value)
        return nil if value.nil?
        value.to_s("F")
      end

      # String (ISO8601) | Date | nil → Date | nil. Rejects Time inputs so
      # day-precision fields don't silently accept instant-precision values.
      def date(value)
        case value
        when nil     then nil
        when DateTime then value.to_date
        when Date    then value
        when String
          return nil if value.strip.empty?
          Date.iso8601(value)
        else
          raise UserError, "canonical: cannot coerce #{value.inspect} to Date"
        end
      end

      def date_to_wire(value)
        value&.iso8601
      end

      # String (ISO8601) | Time | nil → Time (UTC) | nil.
      def time(value)
        case value
        when nil  then nil
        when Time then value.utc
        when String
          return nil if value.strip.empty?
          Time.iso8601(value).utc
        else
          raise UserError, "canonical: cannot coerce #{value.inspect} to Time"
        end
      end

      def time_to_wire(value)
        value&.utc&.iso8601
      end
    end
  end
end
