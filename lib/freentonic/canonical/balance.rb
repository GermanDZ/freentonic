# frozen_string_literal: true

module Freentonic
  module Canonical
    # Current + available balance with fetch timestamp. All three fields
    # optional — some banks expose only `current`, others skip timestamps.
    class Balance < Data.define(:current, :available, :timestamp)
      def self.new(current: nil, available: nil, timestamp: nil)
        super(
          current: Coerce.amount(current),
          available: Coerce.amount(available),
          timestamp: Coerce.time(timestamp)
        )
      end

      def to_h
        {
          "current" => Coerce.amount_to_wire(current),
          "available" => Coerce.amount_to_wire(available),
          "timestamp" => Coerce.time_to_wire(timestamp)
        }
      end
    end
  end
end
