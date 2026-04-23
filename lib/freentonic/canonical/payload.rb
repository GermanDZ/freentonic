# frozen_string_literal: true

module Freentonic
  module Canonical
    # Top-level envelope returned by the Normalize stage after the canonical
    # migration. Wraps four entity slots plus free-form meta and emits a
    # framework-computed summary by default.
    #
    # Authors call:
    #
    #   CanonicalPayload.new(
    #     accounts: [Canonical::Account.new(...), ...],
    #     transactions: [Canonical::Transaction.new(...), ...],
    #     meta: { "scraper_version" => "1.2.3" }
    #   )
    #
    # Summary is computed at construction. To skip computation (or supply a
    # hand-rolled rollup), pass `summary:` explicitly — anything other than
    # the AUTO sentinel is used as-is.
    class CanonicalPayload
      AUTO = :__auto__

      attr_reader :accounts, :transactions, :liabilities, :investments,
                  :meta, :summary

      def initialize(accounts: [], transactions: [], liabilities: [],
                     investments: [], meta: {}, summary: AUTO)
        @accounts = accounts.dup.freeze
        @transactions = transactions.dup.freeze
        @liabilities = liabilities.dup.freeze
        @investments = investments.dup.freeze
        @meta = (meta || {}).dup.freeze
        @summary = summary == AUTO ? compute_summary : summary
        freeze
      end

      def schema_version
        SCHEMA_VERSION
      end

      def to_h
        {
          "schema_version" => SCHEMA_VERSION,
          "summary" => summary,
          "meta" => meta,
          "accounts" => accounts.map(&:to_h),
          "transactions" => transactions.map(&:to_h),
          "liabilities" => liabilities.map(&:to_h),
          "investments" => investments.map(&:to_h)
        }
      end

      def ==(other)
        other.is_a?(CanonicalPayload) && other.to_h == to_h
      end
      alias_method :eql?, :==

      def hash
        to_h.hash
      end

      private

      def compute_summary
        Summary.compute(
          accounts: accounts,
          transactions: transactions,
          liabilities: liabilities,
          investments: investments
        )
      end
    end
  end
end
