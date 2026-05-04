# `capture_response_header`

Lifts a header value off an HTTP response observed during the browser
phase and stores it in the workflow context.

## Syntax

```yaml
- action: capture_response_header
  host: api.example.com
  path: /auth/token
  header: Authorization
  as: bearer_token
  required: true
```

## Options

| Option     | Type      | Required | Default | Description |
| ---------- | --------- | -------- | ------- | ----------- |
| `host`     | `string`  | **yes**  | —       | Substring of the response URL's host. |
| `path`     | `string`  | **yes**  | —       | Substring of the response URL's path. The full URL must contain both `host` and `path` to match. |
| `header`   | `string`  | **yes**  | —       | Header name to extract. Matched case-insensitively. |
| `as`       | `string`  | **yes**  | —       | Context key under which to store the captured value. |
| `required` | `boolean` | no       | `true`  | When `true`, raises `UserError` if no match is found. When `false`, silently leaves the context key unset. |

## Behaviour

- Walks the CDP `Network.responseReceived` events captured during the
  browser phase, plus correlated `Network.responseReceivedExtraInfo`
  events when present.
- Selects events whose response URL contains both `host` and `path`.
- Reads the named header from the response (case-insensitive). When
  both event types carry the header, the `responseReceivedExtraInfo`
  value wins — Chrome occasionally redacts sensitive headers on the
  public-facing snapshot while leaving the raw value on extra-info.
- The most recent matching event wins, so a fresh-login handshake that
  hits the same endpoint twice resolves to the live value, not the
  stale one.
- Trims surrounding whitespace.
- Never logs the value itself — bearer tokens, signed JWTs, and
  short-lived sessions are exactly what this action captures.

## Use case — PSD2 SCA elevation handshake

Some banks (ING, Unicaja for `límites`, others) require a fresh
strong-customer-authentication challenge before serving full account
history. The post-elevation bearer is minted by an endpoint hit during
the handshake; capture it once and feed it to the api_client as a
credential that subsequent extractor requests use:

```yaml
phases:
  capture_credentials:
    - action: wait_network_idle
      seconds: 3
    - action: capture_response_header
      host: api.ing.ingdirect.es
      path: /saf/tpa/accesstoken/synchronize
      header: Authorization
      as: bearer_token

credentials:
  require: [bearer_token]
  validate:
    - { key: bearer_token, not_empty: true }
  map:
    - { from: bearer_token, as: bearer_token }
```

The api_client's `auth_header "Authorization", from: :bearer_token`
declaration then ships the captured value on every subsequent request.
For mid-extraction rotation (e.g. a post-elevation refresh that
returns a new bearer), see `ApiClient#update_auth_headers!`.

## See also

- [`capture_cookie_header`](workflow-action-capture-cookie-header.md)
- [`capture_header`](workflow-action-capture-header.md) — capture a request header
- [Workflow Actions Reference](workflow-actions.md)
