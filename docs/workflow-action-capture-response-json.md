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
| `required`         | `boolean` | no       | `true`  | When `true`, raises `UserError` if the field is not found. When `false`, silently returns `nil`. |

## Behaviour

- Searches `session.pending_events` for `Network.responseReceived`
  events matching `url_includes` (and not matching `exclude_url`).
- For each matching response (newest first), calls
  `Network.getResponseBody` to retrieve the body and parses it as JSON.
- Returns the first non-nil value for the given `field`.
- On retries, sends a no-op `Runtime.evaluate` to flush pending events.

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
