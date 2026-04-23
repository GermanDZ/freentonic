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
    # parse_date, parse_timestamp_ms, safe_fetch as instance methods
    # automatically). Defines class-level constants `Builder` and
    # `LegacyKeys` aliasing the gem's CanonicalBuilder and LegacyKeys
    # — Ruby's constant lookup walks the inheritance chain so subclasses
    # see them as if they'd declared the alias themselves.
    #
    # The `provider!(dir)` class macro replaces every other piece of
    # header boilerplate. It:
    #
    #   1. Loads <dir>/legacy.yml via LegacyKeysLoader.load_provider!.
    #   2. Loads <dir>/config.yml via Config.load_provider!.
    #   3. If config.yml exists, defines `CONFIG` as a class constant
    #      pointing at the parsed config hash.
    #   4. For every top-level key in config.yml, defines an UPCASE
    #      class constant — so `institution: ing` becomes
    #      `INSTITUTION = "ing"`, `kind_by_type: {...}` becomes
    #      `KIND_BY_TYPE = {...}`. Frozen.
    #
    # Provider-specific lookup tables that don't already live in
    # config.yml stay as explicit constant assignments in the
    # subclass. The macro doesn't fight those — it only adds, never
    # overwrites.
    #
    # Typical provider header (compare with the pre-NormalizerBase
    # version which was 8-15 lines of imports + aliases + constants):
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
      include Freentonic::Providers::Helpers

      Builder    = Freentonic::Providers::CanonicalBuilder
      LegacyKeys = Freentonic::Providers::LegacyKeys

      class << self
        def provider!(dir)
          Freentonic::Providers::LegacyKeysLoader.load_provider!(dir)
          Freentonic::Providers::Config.load_provider!(dir)

          institution_sym = File.basename(dir).to_sym
          cfg = Freentonic::Providers::Config.for(institution_sym)
          return if cfg.nil?  # provider opted out of config.yml

          const_set(:CONFIG, cfg) unless const_defined?(:CONFIG, false)

          cfg.each do |key, value|
            const_name = key.to_s.upcase.to_sym
            next if const_defined?(const_name, false)  # don't overwrite explicit assignments
            const_set(const_name, value.is_a?(Hash) || value.is_a?(Array) ? value.dup.freeze : value)
          end
        end
      end
    end
  end
end
