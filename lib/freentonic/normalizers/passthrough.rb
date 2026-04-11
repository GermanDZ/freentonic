# frozen_string_literal: true

module Freentonic
  module Normalizers
    # Identity normalizer: returns the raw payload untouched. Used when a
    # workflow YAML declares no `normalize:` block.
    class Passthrough < Base
      def call(raw, context: {})
        raw
      end
    end
  end
end
