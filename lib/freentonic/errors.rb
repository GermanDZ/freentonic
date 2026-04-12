# frozen_string_literal: true

module Freentonic
  # User-facing errors: surfaced with `abort error.message` by the CLI, so
  # message text should be actionable (what went wrong + what to do next).
  class UserError < StandardError; end

  # Raised when an exporter fails to write its output. Subclasses of this
  # should add context (HTTP status, path, etc.) via `message`.
  class ExportError < UserError; end
end
