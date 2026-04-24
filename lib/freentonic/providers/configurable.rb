# frozen_string_literal: true

module Freentonic
  module Providers
    # Mixin for "provider-aware" classes — extracts the `provider!(dir)`
    # macro that NormalizerBase and ExtractorBase both want. Extend this
    # in any class that should be configured by a per-provider directory
    # layout (config.yml).
    #
    # The macro:
    #   1. Loads <dir>/config.yml via Config.load_provider!.
    #   2. If config.yml exists, defines `CONFIG` as a class constant
    #      pointing at the parsed config hash.
    #   3. For every top-level key in config.yml, defines an UPCASE
    #      class constant — so `institution: ing` becomes
    #      `INSTITUTION = "ing"`, `kind_by_type: {...}` becomes
    #      `KIND_BY_TYPE = {...}`. Frozen.
    #
    # Provider-specific constants that don't already live in config.yml
    # stay as explicit assignments in the subclass. The macro doesn't
    # fight those — it only adds, never overwrites.
    module Configurable
      def provider!(dir)
        Freentonic::Providers::Config.load_provider!(dir)

        institution_sym = File.basename(dir).to_sym
        cfg = Freentonic::Providers::Config.for(institution_sym)
        return if cfg.nil?

        const_set(:CONFIG, cfg) unless const_defined?(:CONFIG, false)

        cfg.each do |key, value|
          const_name = key.to_s.upcase.to_sym
          next if const_defined?(const_name, false)
          const_set(const_name, value.is_a?(Hash) || value.is_a?(Array) ? value.dup.freeze : value)
        end
      end
    end
  end
end
