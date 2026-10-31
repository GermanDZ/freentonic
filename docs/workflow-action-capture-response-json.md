# `capture_response_json`

Extracts a JSON field from a response body of a matching network
request and stores it in the workflow context. Useful for capturing
OAuth tokens or session identifiers returned in API responses during
the login flow.

## Syntax

```yaml
- action: capture_response_json
  url_includes: /oauth2/token
  exclude_url: /revoke
  field: access_token
  as: access_token
  retries: 3
  interval_seconds: 1
  required: true
```

## Options

| Option             | Type      | Required | Default | Description |
| ------------------ | --------- | -------- | ------- | ----------- |
| `url_includes`     | `string`  | **yes**  | —       | Substring to match against response URLs in buffered `Network.responseReceived` events. |
| `field`            | `string`  | **yes**  | —       | Top-level JSON field name to extract from the response body. |
| `as`               | `string`  | **yes**  | —       | Context key to store the extracted value under. |
| `exclude_url`      | `string`  | no       | —       | Substring to exclude — responses whose URL contains this string are skipped. Useful for filtering out revoke/logout endpoints that match the same base pattern. |
| `retries`          | `integer` | no       | `0`     | Number of times to retry if the field is not found. |
| `interval_seconds` | `number`  | no       | `1`     | Seconds to sleep between retries. |
| `required`         | `boolean` | no       | `true`  | When `true`, raises `UserError` if the field is not found. When `false`, silently returns `nil` (with `all: true`, stores `[]` when no response matched). |
| `all`              | `boolean` | no       | `false` | When `true`, collects the field from **every** matching response, oldest first, and stores the list — for paginated loads where each page is its own response (see [`click_while_present`](workflow-action-click-while-present.md)). Strict: any matched response without the field fails the step. Validated at load. |

## Behaviour

- Searches `session.pending_events` for `Network.responseReceived`
  events matching `url_includes` (and not matching `exclude_url`).
- For each matching response (newest first), calls
  `Network.getResponseBody` to retrieve the body and parses it as JSON.
- Returns the first non-nil value for the given `field` (`false` is a
  value, not a miss). Bodies are base64-decoded when Chrome sends them
  encoded.
- With `all: true`: walks every matching response in arrival order
  (oldest first, one entry per request) and stores the list. It is
  **strict**: if any matched response has no retrievable body or lacks the
  field, the step fails — a silently dropped page would be a silent gap in
  the data. `required` only decides what happens when *nothing* matched
  (raise, or store `[]`). Retries apply to both cases.
- On retries, sends a no-op `Runtime.evaluate` to flush pending events.

## Capturing data from a web app's own responses

When a bank's API can't be called from outside the browser (for example,
its requests are encrypted in the page), the data comes from the responses
the web app itself receives: capture them here, declare them in the
workflow's [`captured:`](extract-plan.md#reading-captured-values-captured)
block, and reshape them in an `extract: plan:`. Only a response the page
actually fetched **during this browser session** can be read (the step
looks through the responses buffered since the run started), which makes
this sensitive to how the page loads:

- **The app has to make the call.** Many web apps send a full page load
  as plain server-rendered HTML with the data already embedded, so no
  API request happens. Only navigation *inside* the running app (a click on
  one of its links) fetches over the API. So reach the screens with
  `click`, not `navigate`.
- **Let the page become the app before clicking.** Such a page turns
  interactive (hydrates) a few seconds after it renders. A click in that
  window does nothing, or is handled as a plain link: a full page load,
  so no request to capture. After every full page load (`navigate`, a
  login redirect), wait for the page to settle — `wait_network_idle` with
  a generous `seconds:` — before the first click.
- **Read the failure message.** When nothing is captured, the error says
  which of the three causes it was: *no matching response was seen* (the
  app made no call — usually the two points above), *no retrievable body*
  (Chrome no longer holds it, e.g. after a navigation; capture sooner), or
  *without the field* (an error payload; look at what the app received).
- **Retry from a settled page, not with a longer sleep.** If a capture can
  still miss, capture with `required: false`, then gate a second attempt
  on its absence with
  [`when_context: { <as>: { absent: true } }`](workflow-when-context.md):
  navigate back, settle, click again, and capture with `required: true`.
- **Match narrowly.** `url_includes` is a substring, so `op=getSpace` also
  matches `op=getSpaceTransactions`. Use `exclude_url`, order captures so
  the wrong one hasn't arrived yet, and have the plan check what it got
  (an id the plan `abort:`s without) rather than trusting the match.
- **History behind "Load more".** Page with
  [`click_while_present`](workflow-action-click-while-present.md)
  (`wait_for_response` so each click proves it fetched a page, and
  `stop_when_older_than_lookback` so a sync loads only its lookback), then
  capture every page with `all: true`. Filter the plan on `{from_ms}` too:
  the last page loaded straddles the window start.

A complete example is the N26 provider in freentonic-providers
(`n26/workflow.yml`).

## Example

```yaml
phases:
  capture_credentials:
    - action: wait_network_idle
      seconds: 3
    - action: capture_response_json
      url_includes: /oauth2/token
      exclude_url: /revoke
      field: access_token
      as: access_token
      retries: 5
      interval_seconds: 1
```

## See also

- [`capture_header`](workflow-action-capture-header.md) — capture a request header
- [`capture_cookie_header`](workflow-action-capture-cookie-header.md) — capture cookies
- [`record_requests`](workflow-action-record-requests.md) — record full request/response pairs for investigation
- [Workflow Actions Reference](workflow-actions.md)
