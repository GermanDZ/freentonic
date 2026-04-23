# frozen_string_literal: true

module Freentonic
  module Canonical
    # Optional merchant information attached to a Transaction.
    # `normalized` = true means `name` has been cleaned up by the normalizer
    # (e.g., "AMZN Mktp ES*XYZ" → "Amazon").
    class Merchant < Data.define(:name, :normalized)
      def self.new(name: nil, normalized: false)
        super(
          name: name&.to_s,
          normalized: normalized ? true : false
        )
      end

      def to_h
        { "name" => name, "normalized" => normalized }
      end
    end
  end
end
