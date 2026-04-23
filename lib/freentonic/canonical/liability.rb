# frozen_string_literal: true

module Freentonic
  module Canonical
    # Debts: credit cards, loans, mortgages, etc.
    #
    # Required fields: id, type, currency.
    class Liability < Data.define(:id, :source_id, :type, :account_id,
                                  :balance, :limit, :currency, :due_date,
                                  :metadata)
      def self.new(id:, type:, currency:,
                   source_id: nil, account_id: nil, balance: nil, limit: nil,
                   due_date: nil, metadata: {})
        super(
          id: id.to_s,
          source_id: source_id&.to_s,
          type: type.to_s,
          account_id: account_id&.to_s,
          balance: Coerce.amount(balance),
          limit: Coerce.amount(limit),
          currency: currency.to_s,
          due_date: Coerce.date(due_date),
          metadata: (metadata || {}).dup
        )
      end

      def to_h
        {
          "id" => id,
          "source_id" => source_id,
          "type" => type,
          "account_id" => account_id,
          "balance" => Coerce.amount_to_wire(balance),
          "limit" => Coerce.amount_to_wire(limit),
          "currency" => currency,
          "due_date" => Coerce.date_to_wire(due_date),
          "metadata" => metadata
        }
      end
    end
  end
end
