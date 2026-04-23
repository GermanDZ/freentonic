# frozen_string_literal: true

# Freentonic::Formatters — converts a CanonicalPayload into a wire-shaped
# value (Hash/Array for JSON-ish formats, String for text-ish formats).
# See docs/formatters.md.
#
# Pure addition: no exporter consumes this yet. PR 3 wires --export-format
# into the CLI and Exporters::Base; PR 4 rewrites the csv/jsonl exporters
# to delegate here.

module Freentonic
  module Formatters
  end
end

require_relative "formatters/base"
require_relative "formatters/canonical"
require_relative "formatters/csv_transactions"
require_relative "formatters/jsonl_transactions"
