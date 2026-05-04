# Workflow Actions Reference

This is the complete reference for every action available in freentonic
workflow YAML files. Each action has its own dedicated doc page with full
option tables, behaviour notes, and examples.

## Actions by category

### Navigation & waiting

| Action | Description | Docs |
| ------ | ----------- | ---- |
| `navigate` | Navigate Chrome to a URL | [workflow-action-navigate.md](workflow-action-navigate.md) |
| `reload` | Reload the current page | [workflow-action-reload.md](workflow-action-reload.md) |
| `wait` | Sleep for a fixed number of seconds | [workflow-action-wait.md](workflow-action-wait.md) |
| `wait_url` | Block until the page URL contains a substring | [workflow-action-wait-url.md](workflow-action-wait-url.md) |
| `wait_network_idle` | Drain CDP events for N seconds | [workflow-action-wait-network-idle.md](workflow-action-wait-network-idle.md) |
| `wait_for_selector` | Block until a CSS selector exists in the DOM | [workflow-action-wait-for-selector.md](workflow-action-wait-for-selector.md) |
| `wait_for_first_of` | Block until any of several selectors exist | [workflow-action-wait-for-first-of.md](workflow-action-wait-for-first-of.md) |
| `wait_for_shadow_selector` | Block until a selector exists inside a shadow root | [workflow-action-wait-for-shadow-selector.md](workflow-action-wait-for-shadow-selector.md) |

### Interaction

| Action | Description | Docs |
| ------ | ----------- | ---- |
| `click` | Click a CSS selector (required) | [workflow-action-click.md](workflow-action-click.md) |
| `click_if_present` | Click a CSS selector (no-op if absent) | [workflow-action-click.md](workflow-action-click.md) |
| `click_text` | Click an element by its visible text content | [workflow-action-click-text.md](workflow-action-click-text.md) |
| `fill` | Type text into a form input (required) | [workflow-action-fill.md](workflow-action-fill.md) |
| `fill_if_present` | Type text into a form input (no-op if absent) | [workflow-action-fill.md](workflow-action-fill.md) |
| `enter_pin_pad` | Enter a PIN via a visual keypad | [workflow-action-enter-pin-pad.md](workflow-action-enter-pin-pad.md) |
| `enter_digits` | Click digit buttons on a keypad one by one | [workflow-action-enter-digits.md](workflow-action-enter-digits.md) |
| `prompt_stdin_and_fill` | Read a one-shot code from the terminal and type it | [workflow-action-prompt-stdin-and-fill.md](workflow-action-prompt-stdin-and-fill.md) |

### Credential capture

| Action | Description | Docs |
| ------ | ----------- | ---- |
| `capture_header` | Extract an HTTP header value into context | [workflow-action-capture-header.md](workflow-action-capture-header.md) |
| `capture_cookie_header` | Build a Cookie header for a host/path and store it | [workflow-action-capture-cookie-header.md](workflow-action-capture-cookie-header.md) |
| `capture_response_header` | Lift a header value off a matching HTTP response into context | [workflow-action-capture-response-header.md](workflow-action-capture-response-header.md) |
| `capture_response_json` | Extract a JSON field from a response body | [workflow-action-capture-response-json.md](workflow-action-capture-response-json.md) |
| `capture_outbound_request_headers` | Snapshot named headers off a recent matching outbound request | [workflow-action-capture-outbound-request-headers.md](workflow-action-capture-outbound-request-headers.md) |
| `capture_local_storage` | Snapshot localStorage for a security origin into context | [workflow-action-capture-local-storage.md](workflow-action-capture-local-storage.md) |
| `capture_session_storage` | Snapshot sessionStorage for a security origin into context | [workflow-action-capture-local-storage.md](workflow-action-capture-local-storage.md) |
| `capture_url` | Store the current page URL into context | [workflow-action-capture-url.md](workflow-action-capture-url.md) |
| `elevate_session` | Drive PSD2 SCA elevation in the live Chrome session, surface operator prompt | [workflow-action-elevate-session.md](workflow-action-elevate-session.md) |

### Investigation (provider authoring only)

| Action | Description | Docs |
| ------ | ----------- | ---- |
| `record_requests` | Start recording matching network traffic | [workflow-action-record-requests.md](workflow-action-record-requests.md) |
| `dump_requests` | Flush recorded traffic to a file | [workflow-action-dump-requests.md](workflow-action-dump-requests.md) |
| `pause` | Wait for the user to press Enter (manual exploration) | [workflow-action-pause.md](workflow-action-pause.md) |

### Other

| Action | Description | Docs |
| ------ | ----------- | ---- |
| `note` | Print a message to stdout | [workflow-action-note.md](workflow-action-note.md) |

## Cross-cutting features

### `error_signals` (early abort on screen errors)

Define patterns in `config.error_signals` to detect bank error pages
(anti-fraud blocks, session errors) during wait loops. When matched,
the workflow takes a screenshot and aborts immediately instead of waiting
for the full timeout. See [workflow-error-signals.md](workflow-error-signals.md).

### `when_context` (conditional execution)

Any step can include a `when_context` gate to run conditionally based
on runtime context values. See [workflow-when-context.md](workflow-when-context.md).

### Secret references

Step values can reference secrets with `"secret(NAME)"`. The secret is
resolved through the configured backend (keychain, plain_file, cli).
See the main [README.md](../README.md#secrets) for backend setup.

### Shadow DOM & iframe traversal

Actions that accept CSS selectors (`click`, `fill`, `wait_for_selector`,
etc.) use a `deepQuery` function that automatically traverses shadow
roots and same-origin iframes. You do not need special syntax — a
regular CSS selector will find elements inside nested shadow DOMs.

## See also

- [README.md](../README.md) — quickstart, pipeline overview, exporters
- [SECURITY.md](../SECURITY.md) — threat model and invariants
- [writing-plugins.md](writing-plugins.md) — extending freentonic with custom exporters, backends, normalizers
- [examples/example_bank.yml](../examples/example_bank.yml) — annotated example workflow
