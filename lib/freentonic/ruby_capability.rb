# frozen_string_literal: true

require_relative "errors"

module Freentonic
  # Runtime gate for provider-authored Ruby (`extract: ruby:`,
  # `normalize: ruby:`, `api_client.ext`). Declarative plans are the default;
  # provider Ruby is a supported but OPT-IN authoring mode. A server is
  # declarative-only unless the operator sets FREENTONIC_ALLOW_PROVIDER_RUBY,
  # which makes "no provider-authored code runs during a sync" a runtime-
  # enforced invariant rather than a convention.
  #
  # The gate fires at run entry (Engine#run), before any stage builds or the
  # api_client is constructed — so a declarative-only server refuses a Ruby
  # workflow before Chrome launches or a single request is made, never
  # mid-sync. It is a *sync* concern only: `--lint` still loads and validates
  # provider Ruby (it just notes the requirement), and library callers that
  # build a Ruby normalizer directly (tests, golden dumps) are unaffected.
  module RubyCapability
    ENV_VAR = "FREENTONIC_ALLOW_PROVIDER_RUBY"

    # Values that count as "on". Anything else (unset, "0", "false", "") is
    # declarative-only — the secure default.
    TRUTHY = %w[1 true yes on].freeze

    module_function

    def enabled?
      TRUTHY.include?(ENV[ENV_VAR].to_s.strip.downcase)
    end

    # Raise unless provider Ruby is enabled. `features` is a human-readable
    # list of the Ruby integration points this run would execute (e.g.
    # ["normalize: ruby:"]). No-op when the list is empty or the gate is on.
    def ensure_enabled!(features)
      features = Array(features).reject { |f| f.to_s.strip.empty? }
      return if features.empty? || enabled?

      raise UserError,
            "This workflow uses provider Ruby (#{features.join(", ")}), but freentonic " \
            "is running in declarative-only mode, so no provider-authored code runs " \
            "during a sync. To allow it, start freentonic with #{ENV_VAR}=1."
    end
  end
end
