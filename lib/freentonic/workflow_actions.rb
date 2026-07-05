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
      "note"                            => { required: %w[message] },
      "note_if_selector"                => { required: %w[selector message] },
      "navigate"                        => { required: %w[url] },
      "reload"                          => { required: [] },
      "wait"                            => { required: %w[seconds] },
      "wait_url"                        => { required: %w[includes], optional: %w[timeout] },
      "await_external_approval"         => { required: %w[message url_includes], optional: %w[timeout] },
      "wait_network_idle"               => { required: [], optional: %w[seconds] },
      "capture_header"                  => { required: %w[name as], optional: %w[retries interval_seconds required] },
      "capture_cookie_header"           => { required: %w[host path as], optional: %w[required] },
      "capture_response_header"         => { required: %w[host path header as], optional: %w[required] },
      "elevate_session"                 => { required: %w[wait_for_first_of], optional: %w[on_sca navigate_to trigger_selector] },
      "capture_local_storage"           => { required: %w[origin as], optional: %w[keys required] },
      "capture_session_storage"         => { required: %w[origin as], optional: %w[keys required] },
      "capture_outbound_request_headers" => { required: %w[host path headers as], optional: %w[most_recent required] },
      "capture_response_json"           => { required: %w[url_includes field as], optional: %w[exclude_url retries interval_seconds required] },
      "wait_for_selector"               => { required: %w[selector], optional: %w[timeout] },
      "wait_for_first_of"               => { required: %w[selectors], optional: %w[timeout] },
      "wait_for_shadow_selector"        => { required: %w[host selector], optional: %w[timeout] },
      "enter_pin_pad"                   => { required: %w[selector pin] },
      "click"                           => { required: %w[selector] },
      "click_if_present"                => { required: %w[selector] },
      "click_text"                      => { required: %w[text], optional: %w[role within match timeout] },
      "fill"                            => { required: %w[selector value], optional: %w[clear] },
      "fill_if_present"                 => { required: %w[selector value], optional: %w[clear] },
      "enter_digits"                    => { required: %w[digits keypad] },
      "prompt_stdin_and_fill"           => { required: %w[selector prompt timeout], optional: %w[submit_selector mask if_present] },
      "record_requests"                 => { required: %w[url_matches], optional: %w[include_response_body max_body_bytes max_entries] },
      "dump_requests"                   => { required: %w[path], optional: %w[format reset] },
      "pause"                           => { required: %w[message timeout] },
      "capture_url"                     => { required: %w[as] },
      "simulate_human"                  => { required: [], optional: %w[duration] },
      "screenshot"                      => { required: [], optional: %w[label] }
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
