# `capture_outbound_request_headers`

Snapshots a chosen subset of headers from a recent outbound HTTP request
matching `host` + `path`, and stores them in the workflow context as a
Hash. Used to lift JS-computed auth headers (Authorization, XSRF
tokens, signed session contexts) off the live browser session — values
the frontend constructs from in-memory state that the headless API
extractor cannot reproduce.

## Syntax

```yaml
- action: capture_outbound_request_headers
  host: "api.bank.example"
  path: "/v2/products/"
  headers:
    - "Authorization"
    - "X-XSRF-TOKEN"
    - "X-Bank-ExtendedSessionContext"
  as: bank_api_headers                   # → ctx.<as> (Hash of name → value)
  most_recent: true
  required: true
```

## Options

| Option        | Type    | Required | Default | Description |
| ------------- | ------- | -------- | ------- | ----------- |
| `host`        | string  | **yes**  | —       | Substring of the request URL's host. |
| `path`        | string  | **yes**  | —       | Substring of the request URL's path. The full URL must contain both `host` and `path` to match. |
| `headers`     | array   | **yes**  | —       | Header names to capture. Matched case-insensitively. |
| `as`          | string  | **yes**  | —       | Context key to store the result under. |
| `most_recent` | boolean | no       | `true`  | When `true`, picks the most recent matching request (typical — fresh-login handshakes often dispatch several before the live values settle). When `false`, picks the first. |
| `required`    | boolean | no       | `true`  | When `true`, raises `UserError` if no matching request was observed. When `false`, leaves the context key unset and continues. |

## Behaviour

- Walks the captured `Network.requestWillBeSent` events from the live
  Chrome session.
- Filters by URL containing both `host` and `path`.
- Pulls the listed headers (case-insensitive) from the matching request.
- Also consults correlated `Network.requestWillBeSentExtraInfo` events
  for the post-CORS raw headers some Chrome versions only put there;
  ExtraInfo wins on collision.
- The resulting Hash is keyed by the caller-requested spelling (so
  `ctx[as]["Authorization"]` works regardless of whether Chrome
  reported it as `authorization`).
- Header values are NEVER logged — only header names appear in stdout.

## See also

- [`capture_response_header`](workflow-action-capture-response-header.md) — for response-side headers
- [`capture_cookie_header`](workflow-action-capture-cookie-header.md)
- [`elevate_session`](workflow-action-elevate-session.md) — typically runs before this
- [Workflow Actions Reference](workflow-actions.md)
