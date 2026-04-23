# frozen_string_literal: true

module Freentonic
  module Providers
    # Base class for provider extractors. Mirror of NormalizerBase on
    # the extract side — keeps the per-provider extractor down to
    # imports + the `call` method + provider-specific fetch logic.
    #
    # Includes Freentonic::Providers::Helpers (so subclasses get
    # safe_fetch, cents, parse_date, parse_timestamp_ms, extract_fields,
    # first_present as instance methods automatically) and exposes the
    # `provider!(dir)` class macro that loads <dir>/legacy.yml +
    # <dir>/config.yml and auto-defines CONFIG + UPCASE constants from
    # the config keys (see Configurable for details).
    #
    # Unlike NormalizerBase, ExtractorBase does NOT inherit from any
    # framework abstract class — the Extract stage treats whatever's
    # named in `extract.class` as a duck-typed call(client:, credentials:,
    # from_date:, stdout:, stderr:) responder.
    #
    # Typical provider extractor:
    #
    #   require "freentonic"
    #
    #   module Freentonic::Providers::Ing
    #     class Extractor < Freentonic::Providers::ExtractorBase
    #       provider!(__dir__)
    #
    #       def call(client:, credentials:, from_date:, stdout:, stderr:)
    #         # ...
    #       end
    #     end
    #   end
    class ExtractorBase
      extend Freentonic::Providers::Configurable
      include Freentonic::Providers::Helpers
    end
  end
end
