# `elevate_session`

Drives PSD2 SCA elevation (or any equivalent challenge) inside the live
Chrome session. The bank's frontend is the only context that can mint
post-elevation state — out-of-browser refresh-token flows are commonly
rejected with full HAR-parity headers — so the action triggers the
challenge by interacting with the page, surfaces an operator prompt
when the bank presents one, and waits for the elevation-complete signal.

After this lands, capture the elevated state with
[`capture_cookie_header`](workflow-action-capture-cookie-header.md),
[`capture_local_storage`](workflow-action-capture-local-storage.md),
and/or [`capture_outbound_request_headers`](workflow-action-capture-outbound-request-headers.md)
in the next phase.

## Syntax

```yaml
- action: elevate_session
  when_context:                                       # optional gate
    lookback_days: { gt: 60 }
  navigate_to: "https://bank.example/account/extended-history"
  trigger_selector: "#load-more"
  wait_for_first_of:
    timeout: 10
    branches:
      - selector: "[data-element='sca-dialog']"
        on_match: sca
      - selector: ".transactions-list-loaded"
      - url_includes: "?elevated=true"
  on_sca:
    prompt: "Approve in your bank's mobile app and tap notification"
    prompt_timeout: 180     # optional; defaults to wait_for_first_of.timeout below
    wait_for_first_of:
      timeout: 180
      branches:
        - selector: ".transactions-list-loaded"
        - url_includes: "?elevated=true"
```

## Options

| Option            | Type    | Required | Default | Description |
| ----------------- | ------- | -------- | ------- | ----------- |
| `when_context`    | hash    | no       | —       | Standard skip-gate (see [when_context](workflow-when-context.md)). Typical: `{ lookback_days: { gt: 60 } }`. |
| `navigate_to`     | string  | no       | —       | URL to navigate to before triggering. Skipped when absent (the current page is assumed to be the trigger surface). |
| `trigger_selector`| string  | no       | —       | DOM selector to click. Optional — sometimes the navigation alone fires SCA. Click is best-effort (`click_if_present` semantics). |
| `wait_for_first_of` | hash  | **yes**  | —       | First-pass signals. See *Branches* below. |
| `on_sca`          | hash    | conditional | — | Required when any branch in `wait_for_first_of` carries `on_match: sca`. See *on_sca* below. |

### Branches

`wait_for_first_of.branches` and `on_sca.wait_for_first_of.branches` are
arrays of branches. Each branch has either a `selector:` (matched when
the DOM element is present) or a `url_includes:` (matched when the
current URL contains the substring), and optionally an `on_match:` tag.

The first matching branch wins. When a branch carries `on_match: sca`,
the runner enters the SCA-prompt path; otherwise it considers the
session already elevated and continues.

### `on_sca`

| Option                         | Type    | Required | Default | Description |
| ------------------------------ | ------- | -------- | ------- | ----------- |
| `prompt`                       | string  | **yes**  | —       | Operator-facing message. Surfaced via the active prompt channel — terminal when running headed locally, the simplefreen-invoke admin UI when running under the invoke server (via the `[freentonic][prompt]` JSON-line on stderr). |
| `prompt_timeout`               | integer | no       | mirrors `wait_for_first_of.timeout` | Seconds to wait for the operator. |
| `wait_for_first_of.branches`   | array   | **yes**  | —       | Completion signals to wait for after the operator approves. |
| `wait_for_first_of.timeout`    | integer | no       | 180     | Seconds. |

## Behaviour

1. Skipped if `when_context` is set and evaluates to false.
2. If `navigate_to` is set, sends `Page.navigate`.
3. If `trigger_selector` is set, clicks it (best-effort; missing is OK).
4. Waits for any branch in `wait_for_first_of` to match. On timeout,
   raises `UserError` and saves a screenshot for postmortem.
5. If the matching branch carried `on_match: sca`:
   - Surfaces the prompt; blocks until the operator approves or the
     prompt times out.
   - Waits for any branch in `on_sca.wait_for_first_of` to match (the
     elevation-complete signal). On timeout, raises `UserError`.
6. If the matching branch was untagged or carried any other `on_match`
   value, considers the session already elevated and returns.

## See also

- [`capture_cookie_header`](workflow-action-capture-cookie-header.md)
- [`capture_local_storage`](workflow-action-capture-local-storage.md)
- [`capture_outbound_request_headers`](workflow-action-capture-outbound-request-headers.md)
- [`pause`](workflow-action-pause.md) — lower-level operator-blocking primitive
- [Workflow Actions Reference](workflow-actions.md)
