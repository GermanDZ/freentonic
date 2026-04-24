# frozen_string_literal: true

module Freentonic
  module Providers
    # Base class for provider normalizers that absorbs every line of
    # boilerplate the per-provider normalizer used to carry. Goal: keep
    # the per-provider Ruby file down to imports + the actual `call`
    # method + provider-specific business logic helpers, no ceremony.
    #
    # Inherits Freentonic::Normalizers::Base (so it satisfies the
    # workflow stage's normalizer contract). Includes
    # Freentonic::Providers::Helpers (so subclasses get cents,
    # parse_date, parse_timestamp_ms, safe_fetch, extract_fields,
    # first_present as instance methods automatically). Defines the
    # class-level constant `Builder` aliasing the gem's CanonicalBuilder
    # — Ruby's constant lookup walks the inheritance chain so subclasses
    # see it as if they'd declared the alias themselves.
    #
    # The `provider!(dir)` class macro (extended from Configurable)
    # absorbs the per-provider header. See Configurable for what it
    # does. Typical provider header:
    #
    #   require "freentonic"
    #
    #   module Freentonic::Providers::Fintonic
    #     class Normalizer < Freentonic::Providers::NormalizerBase
    #       provider!(__dir__)
    #
    #       def call(raw, context: {})
    #         # ...
    #       end
    #     end
    #   end
    class NormalizerBase < Freentonic::Normalizers::Base
      extend Freentonic::Providers::Configurable
      include Freentonic::Providers::Helpers

      Builder = Freentonic::Providers::CanonicalBuilder
    end
  end
end
