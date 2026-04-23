# frozen_string_literal: true

module Freentonic
  module Canonical
    # Canonical representation of a financial movement.
    #
    # Required fields: id, account_id, amount, currency.
    # `date` is intentionally not required — scraped data frequently omits
    # it, and fabricating a date is worse than leaving it nil.
    class Transaction < Data.define(:id, :source_id, :account_id, :date,
                                    :value_date, :amount, :currency,
                                    :description, :raw_description, :status,
                                    :merchant, :category, :metadata)
      POSTED = "posted"
      PENDING = "pending"

      def self.new(id:, account_id:, amount:, currency:,
                   source_id: nil, date: nil, value_date: nil,
                   description: nil, raw_description: nil, status: nil,
                   merchant: nil, category: nil, metadata: {})
        super(
          id: id.to_s,
          source_id: source_id&.to_s,
          account_id: account_id.to_s,
          date: Coerce.date(date),
          value_date: Coerce.date(value_date),
          amount: Coerce.amount(amount),
          currency: currency.to_s,
          description: description&.to_s,
          raw_description: raw_description&.to_s,
          status: status&.to_s,
          merchant: coerce_merchant(merchant),
          category: category&.to_s,
          metadata: (metadata || {}).dup
        )
      end

      def to_h
        {
          "id" => id,
          "source_id" => source_id,
          "account_id" => account_id,
          "date" => Coerce.date_to_wire(date),
          "value_date" => Coerce.date_to_wire(value_date),
          "amount" => Coerce.amount_to_wire(amount),
          "currency" => currency,
          "description" => description,
          "raw_description" => raw_description,
          "status" => status,
          "merchant" => merchant&.to_h,
          "category" => category,
          "metadata" => metadata
        }
      end

      def self.coerce_merchant(value)
        case value
        when nil then nil
        when Merchant then value
        when Hash then Merchant.new(**value.transform_keys(&:to_sym))
        else
          raise UserError, "canonical: cannot coerce #{value.inspect} to Merchant"
        end
      end
    end
  end
end
