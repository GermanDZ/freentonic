# frozen_string_literal: true

# Freentonic::Canonical — internal data model and Normalize stage output
# contract. See docs/canonical-data-model.md.

module Freentonic
  module Canonical
    # Semver. Bump on rename/remove of any envelope or entity field;
    # additive changes (new optional fields) do NOT bump.
    SCHEMA_VERSION = "0.1"
  end
end

require_relative "canonical/coerce"
require_relative "canonical/ids"
require_relative "canonical/balance"
require_relative "canonical/merchant"
require_relative "canonical/account"
require_relative "canonical/transaction"
require_relative "canonical/liability"
require_relative "canonical/investment"
require_relative "canonical/summary"
require_relative "canonical/payload"
