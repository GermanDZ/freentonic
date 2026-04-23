# frozen_string_literal: true

module Freentonic
  module Canonical
    # Canonical representation of a financial account.
    #
    # Required fields: id, currency.
    class Account < Data.define(:id, :source_id, :institution, :name, :type,
                                :currency, :iban, :balance, :metadata)
      def self.new(id:, currency:,
                   source_id: nil, institution: nil, name: nil, type: nil,
                   iban: nil, balance: nil, metadata: {})
        super(
          id: id.to_s,
          source_id: source_id&.to_s,
          institution: institution&.to_s,
          name: name&.to_s,
          type: type&.to_s,
          currency: currency.to_s,
          iban: iban&.to_s,
          balance: coerce_balance(balance),
          metadata: (metadata || {}).dup
        )
      end

      def to_h
        {
          "id" => id,
          "source_id" => source_id,
          "institution" => institution,
          "name" => name,
          "type" => type,
          "currency" => currency,
          "iban" => iban,
          "balance" => balance&.to_h,
          "metadata" => metadata
        }
      end

      def self.coerce_balance(value)
        case value
        when nil then nil
        when Balance then value
        when Hash then Balance.new(**value.transform_keys(&:to_sym))
        else
          raise UserError, "canonical: cannot coerce #{value.inspect} to Balance"
        end
      end
    end
  end
end
