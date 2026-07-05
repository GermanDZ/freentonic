# frozen_string_literal: true

# Freentonic — declarative YAML-driven data provider scraper.
#
# Pipeline: Connect → Extract → Normalize → Export.
# Each stage is independently runnable. Normalizers, exporters, and secret
# backends are pluggable. Zero runtime gem dependencies (pure stdlib).

module Freentonic
end

require_relative "freentonic/version"
require_relative "freentonic/errors"
require_relative "freentonic/reporter"

require_relative "freentonic/chrome_cdp"
require_relative "freentonic/source_helpers"
require_relative "freentonic/path_confinement"
require_relative "freentonic/workflow_schema"
require_relative "freentonic/remote_prompt_store"
require_relative "freentonic/recorder"
require_relative "freentonic/browser_workflow_runner"
require_relative "freentonic/timestamp_ms"
require_relative "freentonic/api_client"
require_relative "freentonic/source"

require_relative "freentonic/secrets/store"
require_relative "freentonic/secrets/cli"
require_relative "freentonic/secrets/macos_keychain"
require_relative "freentonic/secrets/plain_file"
require_relative "freentonic/secrets/inline_fd"
require_relative "freentonic/secret_resolver"

require_relative "freentonic/canonical"

require_relative "freentonic/normalizers/base"
require_relative "freentonic/normalizers/passthrough"

require_relative "freentonic/providers/helpers"
require_relative "freentonic/providers/canonical_builder"
require_relative "freentonic/providers/config"
require_relative "freentonic/providers/configurable"
require_relative "freentonic/providers/normalizer_base"
require_relative "freentonic/providers/extractor_base"
# scaffold + har_analyzer are authoring tools, not runtime deps — require
# them explicitly from the Rakefile or CLI that needs them.

require_relative "freentonic/exporters/base"
require_relative "freentonic/exporters/json"
require_relative "freentonic/exporters/jsonl"
require_relative "freentonic/exporters/csv"
require_relative "freentonic/exporters/http"

require_relative "freentonic/stages/base"
require_relative "freentonic/stages/connect"
require_relative "freentonic/stages/extract"
require_relative "freentonic/stages/normalize"
require_relative "freentonic/stages/export"

require_relative "freentonic/engine"
require_relative "freentonic/linter"
