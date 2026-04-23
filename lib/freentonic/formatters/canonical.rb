# frozen_string_literal: true

module Freentonic
  module Formatters
    # Identity formatter: returns the CanonicalPayload's wire-ready hash.
    # Default for the http and json exporters after PR 3.
    class Canonical < Base
      def call(payload)
        payload.to_h
      end
    end

    register(:canonical, Canonical)
  end
end
