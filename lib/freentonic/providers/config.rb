# frozen_string_literal: true

require "yaml"

module Freentonic
  module Providers
    # Per-provider declarative config loaded from `<provider>/config.yml`.
    # Companion to LegacyKeysLoader: same YAML safe-load hardening, same
    # data-only philosophy, but for non-legacy provider knobs — institution
    # slug, scraper version, lookup tables (e.g. ING's kind_by_product_type
    # mapping numeric product type codes to canonical kinds).
    #
    # Security: YAML.safe_load with permitted_classes=[] and aliases=false
    # refuses any !ruby/object: tag, alias trickery, and code-execution
    # construct. The contents are pure data — Strings, Integers, Booleans,
    # Arrays, Hashes — and the audit surface for "what's in this provider's
    # config" is a single .yml diff per provider PR.
    #
    # Optional per provider: not every provider has lookup tables or wants
    # YAML metadata. Missing config.yml → load_provider! returns nil.
    #
    # Caching: the parser runs once per institution at first call; subsequent
    # calls return the frozen cached hash. Both extractor and normalizer of
    # the same provider can call load_provider! cheaply.
    #
    # Usage in a provider's normalizer.rb:
    #
    #   require "freentonic"
    #   CONFIG = Freentonic::Providers::Config.load_provider!(__dir__)
    #
    #   INSTITUTION         = CONFIG.fetch(:institution)
    #   SCRAPER_VERSION     = CONFIG.fetch(:scraper_version)
    #   KIND_BY_PRODUCT_TYPE = CONFIG.fetch(:kind_by_product_type)
    module Config
      class InvalidConfigError < StandardError; end

      @configs = {}

      class << self
        # Load <provider_dir>/config.yml, cache by directory basename, return
        # the frozen parsed hash. Returns nil if no config.yml exists (the
        # provider opts out of declarative config). Idempotent.
        def load_provider!(provider_dir)
          institution = File.basename(provider_dir).to_sym
          return @configs[institution] if @configs.key?(institution)

          config_path = File.join(provider_dir, "config.yml")
          unless File.exist?(config_path)
            @configs[institution] = nil
            return nil
          end

          @configs[institution] = parse!(config_path).freeze
        end

        # Lookup a previously-loaded config by institution. Raises if the
        # institution wasn't loaded — calling code should always have already
        # invoked load_provider! at file-load time.
        def for(institution)
          key = institution.to_sym
          unless @configs.key?(key)
            raise InvalidConfigError,
                  "no Config registered for #{institution.inspect}; call " \
                  "Freentonic::Providers::Config.load_provider!(__dir__) first"
          end
          @configs[key]
        end

        # Reset for tests. Not intended for production use.
        def __reset_for_tests!
          @configs = {}
        end

        private

        def parse!(path)
          YAML.safe_load(
            File.read(path),
            permitted_classes: [],
            aliases:           false,
            symbolize_names:   true
          )
        rescue Psych::DisallowedClass, Psych::BadAlias, Psych::SyntaxError => e
          raise InvalidConfigError,
                "#{path}: unsafe or malformed YAML rejected (#{e.class}: #{e.message})"
        end
      end
    end
  end
end
