# `capture_header`

Extracts an HTTP request header value from buffered CDP network events
and stores it in the workflow context. The header is then available to
downstream stages (e.g. as a credential for the API client).

## Syntax

```yaml
- action: capture_header
  name: X-CSRF-Token
  as: csrf_token
  retries: 5
  interval_seconds: 1
  required: true
```

## Options

| Option             | Type      | Required | Default | Description |
| ------------------ | --------- | -------- | ------- | ----------- |
| `name`             | `string`  | **yes**  | —       | HTTP header name to search for in buffered `Network.requestWillBeSent` events. Case-sensitive. |
| `as`               | `string`  | **yes**  | —       | Context key to store the captured value under. Available to later steps and the `credentials` mapping. |
| `retries`          | `integer` | no       | `0`     | Number of times to retry if the header is not found. Between retries, a no-op `Runtime.evaluate` is sent to flush pending CDP events. |
| `interval_seconds` | `number`  | no       | `1`     | Seconds to sleep between retries. |
| `required`         | `boolean` | no       | `true`  | When `true` (default), raises `UserError` if the header is not found after all retries. When `false`, silently returns `nil`. |

## Behaviour

- Searches `session.pending_events` for `Network.requestWillBeSent`
  events whose request headers contain the named header.
- If not found and `retries > 0`, sleeps and retries — useful when the
  browser fires the relevant request slightly after navigation completes.
- Stores the value as `context["<as>"]`.
- Logs `✓ <name>: captured` on success.

## Example

```yaml
phases:
  capture_credentials:
    - action: wait_network_idle
      seconds: 3
    - action: capture_header
      name: tokencsrf
      as: tokencsrf
      retries: 3
      interval_seconds: 1
```

## See also

- [`capture_cookie_header`](workflow-action-capture-cookie-header.md) — capture cookies as a Cookie header
- [`capture_response_json`](workflow-action-capture-response-json.md) — extract a field from a response body
- [`wait_network_idle`](workflow-action-wait-network-idle.md) — ensure network events are available
- [Workflow Actions Reference](workflow-actions.md)
