# frozen_string_literal: true

module Freentonic
  # User-facing errors: surfaced with `abort error.message` by the CLI, so
  # message text should be actionable (what went wrong + what to do next).
  class UserError < StandardError; end

  # Raised when an exporter fails to write its output. Subclasses of this
  # should add context (HTTP status, path, etc.) via `message`.
  class ExportError < UserError; end

  # Raised when a workflow detects that the banking session needs a fresh
  # interactive login (expired device-trust, rotated MFA, etc.) and
  # further headless attempts will not recover on their own. The CLI maps
  # this to exit code 3, which the SimpleFIN bridge translates to the
  # `needs_reauth` state — surfacing a "Re-authenticate via VNC" prompt to
  # the operator without auto-retrying and hammering the bank.
  #
  # Typically produced by an `error_signals` entry with `kind: reauth`,
  # but workflow authors can also raise it directly from a custom action.
  class ReauthRequired < UserError; end
end
