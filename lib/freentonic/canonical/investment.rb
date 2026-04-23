# frozen_string_literal: true

module Freentonic
  module Canonical
    # Investment holdings: stock, fund, crypto, etc.
    #
    # Required fields: id, account_id, symbol, currency.
    class Investment < Data.define(:id, :source_id, :account_id, :type,
                                   :symbol, :quantity, :price, :currency,
                                   :metadata)
      def self.new(id:, account_id:, symbol:, currency:,
                   source_id: nil, type: nil, quantity: nil, price: nil,
                   metadata: {})
        super(
          id: id.to_s,
          source_id: source_id&.to_s,
          account_id: account_id.to_s,
          type: type&.to_s,
          symbol: symbol.to_s,
          quantity: Coerce.amount(quantity),
          price: Coerce.amount(price),
          currency: currency.to_s,
          metadata: (metadata || {}).dup
        )
      end

      def to_h
        {
          "id" => id,
          "source_id" => source_id,
          "account_id" => account_id,
          "type" => type,
          "symbol" => symbol,
          "quantity" => Coerce.amount_to_wire(quantity),
          "price" => Coerce.amount_to_wire(price),
          "currency" => currency,
          "metadata" => metadata
        }
      end
    end
  end
end
