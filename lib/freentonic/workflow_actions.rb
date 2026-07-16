# frozen_string_literal: true

module Freentonic
  # Declarative registry of every workflow action the browser runner knows how
  # to dispatch. This is the single source of truth for:
  #
  #   * the set of valid action names (drives the load-time unknown-action
  #     check in WorkflowSchema — a typo like "navigat" now fails at load
  #     instead of dying mid-run after 2FA), and
  #   * the required keys of every action (load-time presence validation for
  #     all ~33 actions, not just the ~13 that had bespoke validators).
  #
  # `optional` keys are documentation only — they are NOT rejection-validated,
  # so additive keys stay backward-compatible (see workflow schema versioning
  # policy). They exist so this table can later drive `--lint` and generated
  # action docs.
  #
  # The runner's `case action` dispatch (browser_workflow_runner.rb) and this
  # table are kept in lockstep by a drift-guard test — neither may list an
  # action the other omits.
  module WorkflowActions
    # Keys accepted on any step regardless of action.
    UNIVERSAL_KEYS = %w[action when_context].freeze

    # name => { required: [...], optional: [...] }
    #
    # `required` lists keys the runner fetches without a default (its absence
    # is a hard error). `optional` documents the remaining accepted keys.
    SPECS = {
      "note"                            => { required: %w[message], summary: "Print a message to stdout.", doc: "workflow-action-note.md" },
      "note_if_selector"                => { required: %w[selector message], summary: "Print a message to stdout only when a selector is present." },
      "navigate"                        => { required: %w[url], summary: "Navigate Chrome to a URL.", doc: "workflow-action-navigate.md" },
      "reload"                          => { required: [], summary: "Reload the current page.", doc: "workflow-action-reload.md" },
      "wait"                            => { required: %w[seconds], summary: "Sleep for a fixed number of seconds.", doc: "workflow-action-wait.md" },
      "wait_url"                        => { required: %w[includes], optional: %w[timeout], summary: "Block until the page URL contains a substring.", doc: "workflow-action-wait-url.md" },
      "await_external_approval"         => { required: %w[message url_includes], optional: %w[timeout], summary: "Wait for an out-of-band approval until the page URL contains a substring." },
      "wait_network_idle"               => { required: [], optional: %w[seconds], summary: "Drain CDP events for N seconds to let the network settle.", doc: "workflow-action-wait-network-idle.md" },
      "capture_header"                  => { required: %w[name as], optional: %w[retries interval_seconds required], summary: "Extract an HTTP header value into context.", doc: "workflow-action-capture-header.md" },
      "capture_cookie_header"           => { required: %w[host path as], optional: %w[required], summary: "Build a Cookie header for a host/path and store it in context.", doc: "workflow-action-capture-cookie-header.md" },
      "capture_response_header"         => { required: %w[host path header as], optional: %w[required], summary: "Lift a header value off a matching HTTP response into context.", doc: "workflow-action-capture-response-header.md" },
      "elevate_session"                 => { required: %w[wait_for_first_of], optional: %w[on_sca navigate_to trigger_selector], summary: "Drive PSD2 SCA elevation in the live session and surface the operator prompt.", doc: "workflow-action-elevate-session.md" },
      "capture_local_storage"           => { required: %w[origin as], optional: %w[keys required], summary: "Snapshot localStorage for a security origin into context.", doc: "workflow-action-capture-local-storage.md" },
      "capture_session_storage"         => { required: %w[origin as], optional: %w[keys required], summary: "Snapshot sessionStorage for a security origin into context.", doc: "workflow-action-capture-local-storage.md" },
      "capture_outbound_request_headers" => { required: %w[host path headers as], optional: %w[most_recent required], summary: "Snapshot named headers off a recent matching outbound request.", doc: "workflow-action-capture-outbound-request-headers.md" },
      "capture_response_json"           => { required: %w[url_includes field as], optional: %w[exclude_url retries interval_seconds required], summary: "Extract a JSON field from a matching response body into context.", doc: "workflow-action-capture-response-json.md" },
      "wait_for_selector"               => { required: %w[selector], optional: %w[timeout], summary: "Block until a CSS selector exists in the DOM.", doc: "workflow-action-wait-for-selector.md" },
      "wait_for_first_of"               => { required: %w[selectors], optional: %w[timeout], summary: "Block until any of several selectors exist.", doc: "workflow-action-wait-for-first-of.md" },
      "wait_for_shadow_selector"        => { required: %w[host selector], optional: %w[timeout], summary: "Block until a selector exists inside a shadow root.", doc: "workflow-action-wait-for-shadow-selector.md" },
      "enter_pin_pad"                   => { required: %w[selector pin], summary: "Enter a PIN via a visual keypad.", doc: "workflow-action-enter-pin-pad.md" },
      "click"                           => { required: %w[selector], summary: "Click a CSS selector (required).", doc: "workflow-action-click.md" },
      "click_if_present"                => { required: %w[selector], summary: "Click a CSS selector, no-op if absent.", doc: "workflow-action-click.md" },
      "click_text"                      => { required: %w[text], optional: %w[role within match timeout], summary: "Click an element by its visible text content.", doc: "workflow-action-click-text.md" },
      "fill"                            => { required: %w[selector value], optional: %w[clear], summary: "Type text into a form input (required).", doc: "workflow-action-fill.md" },
      "fill_if_present"                 => { required: %w[selector value], optional: %w[clear], summary: "Type text into a form input, no-op if absent.", doc: "workflow-action-fill.md" },
      "enter_digits"                    => { required: %w[digits keypad], summary: "Click digit buttons on a keypad one by one.", doc: "workflow-action-enter-digits.md" },
      "prompt_stdin_and_fill"           => { required: %w[selector prompt timeout], optional: %w[submit_selector mask if_present], summary: "Read a one-shot code from the terminal and type it into a field.", doc: "workflow-action-prompt-stdin-and-fill.md" },
      "record_requests"                 => { required: %w[url_matches], optional: %w[include_response_body max_body_bytes max_entries], summary: "Start recording matching network traffic.", doc: "workflow-action-record-requests.md" },
      "dump_requests"                   => { required: %w[path], optional: %w[format reset], summary: "Flush recorded traffic to a file.", doc: "workflow-action-dump-requests.md" },
      "pause"                           => { required: %w[message timeout], summary: "Wait for the user to press Enter (manual exploration).", doc: "workflow-action-pause.md" },
      "capture_url"                     => { required: %w[as], summary: "Store the current page URL into context.", doc: "workflow-action-capture-url.md" },
      "simulate_human"                  => { required: [], optional: %w[duration], summary: "Perform randomized human-like mouse and scroll activity for a duration." },
      "screenshot"                      => { required: [], optional: %w[label], summary: "Capture a screenshot of the current page." },
      "inspect_page"                    => { required: [], optional: %w[as], summary: "Observe visible interactive elements (selectors/labels, never values) and optionally store the inventory in context.", doc: "workflow-action-inspect-page.md" }
    }.freeze

    module_function

    def names
      SPECS.keys
    end

    def known?(action)
      SPECS.key?(action)
    end

    def required_keys(action)
      Array(SPECS.fetch(action, {})[:required])
    end

    def optional_keys(action)
      Array(SPECS.fetch(action, {})[:optional])
    end
  end
end
