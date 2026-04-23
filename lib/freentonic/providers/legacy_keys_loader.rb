# frozen_string_literal: true

require "yaml"
require_relative "legacy_keys"

module Freentonic
  module Providers
    # Auto-discovers per-provider `legacy.yml` files living next to a
    # workflow.yml and registers them with LegacyKeys. Called once at
    # boot from each provider's normalizer.rb (or once globally — the
    # registration is idempotent).
    #
    # Security posture (belt-and-braces):
    #
    # 1. Parser: YAML.safe_load with `permitted_classes: []` refuses any
    #    `!ruby/object:...` tag, `!!exec`, or anything that would
    #    deserialize into a Ruby object. `aliases: false` refuses YAML
    #    aliases (billion-laughs / reference-sharing trickery). The only
    #    shapes that survive parsing are String / Integer / Float /
    #    Boolean / Array / Hash.
    #
    # 2. Registry: LegacyKeys.register runs its own `validate_spec!`
    #    allowlist — Strings, Arrays of Strings, Hashes with :default /
    #    :if_<value> / leaf-field keys. Anything else raises. Procs /
    #    Symbols / unknown hash keys cannot slip through.
    #
    # Together, the YAML parser refuses unsafe constructs at parse time
    # AND the registry refuses unexpected shapes at register time.
    # A malicious provider PR that edits a legacy.yml has no path to
    # code execution short of changing the loader or LegacyKeys source
    # itself (which is a visibly-reviewable Ruby change, not a config
    # change).
    module LegacyKeysLoader
      class << self
        # Load a single provider's legacy.yml given the provider's
        # directory. Institution name is derived from the directory's
        # basename. Intended usage from a normalizer:
        #
        #   require "freentonic/providers/legacy_keys_loader"
        #   Freentonic::Providers::LegacyKeysLoader.load_provider!(__dir__)
        #
        # Silently no-ops if the provider has no legacy.yml — brand-new
        # providers with no receiver-side legacy data don't have to ship
        # one.
        def load_provider!(provider_dir)
          legacy_path = File.join(provider_dir, "legacy.yml")
          return unless File.exist?(legacy_path)
          load_file!(legacy_path, institution: File.basename(provider_dir))
        end

        # Scan `<root>/*/workflow.yml` to locate provider directories;
        # for each, read a sibling `legacy.yml` if present and register
        # its contents under the provider-directory name as the
        # institution. Useful for bulk loading in tests or tooling.
        def load_all!(root:)
          Dir.glob(File.join(root, "*", "workflow.yml")).sort.each do |workflow_path|
            load_provider!(File.dirname(workflow_path))
          end
        end

        # Load and register a single legacy.yml file. Extracted for
        # testability (fixtures in tmpdirs).
        def load_file!(path, institution:)
          data = parse!(path)
          validate_structure!(data, path: path)
          LegacyKeys.register(institution.to_sym, **data)
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
          raise LegacyKeys::InvalidConfigError,
                "#{path}: unsafe or malformed YAML rejected (#{e.class}: #{e.message})"
        end

        def validate_structure!(data, path:)
          unless data.is_a?(Hash) && data.key?(:account) && data.key?(:transaction)
            raise LegacyKeys::InvalidConfigError,
                  "#{path}: expected a top-level hash with 'account' and 'transaction' keys " \
                  "(got #{data.class}; keys=#{(data.respond_to?(:keys) ? data.keys : nil).inspect})"
          end
        end
      end
    end
  end
end
