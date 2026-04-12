# `record_requests`

Starts recording network traffic for requests whose URL matches at
least one of the given substring patterns. Recording stays active for
the remainder of the workflow run (or until the buffer is reset by
[`dump_requests`](workflow-action-dump-requests.md) with `reset: true`).

**This action is for investigation during provider authoring only. Never
ship it in a production workflow.** See [SECURITY.md](../SECURITY.md)
for the full invariants.

## Syntax

```yaml
- action: record_requests
  url_matches:
    - "bank.example/apis/externo/"
    - "bank.example/services/rest/"
  include_response_body: true
  max_body_bytes: 131072
  max_entries: 500
```

## Options

| Option                  | Type       | Required | Default   | Description |
| ----------------------- | ---------- | -------- | --------- | ----------- |
| `url_matches`           | `string[]` | **yes**  | —         | Substring patterns matched against the full request URL. Case-sensitive, no regex, no glob. At least one non-empty string is required. |
| `include_response_body` | `boolean`  | no       | `false`   | When `true`, calls CDP `Network.getResponseBody` for each matching response and stores the decoded body. When `false`, only request method/URL/headers and response status/headers are recorded. Default is `false` because bodies contain PII and cost memory. |
| `max_body_bytes`        | `integer`  | no       | `65536`   | Maximum bytes to store per response body (64 KB default). Bodies larger than this are truncated and flagged with `"truncated": true` in the entry so downstream readers know it is incomplete. Hard upper bound: **4194304** (4 MB), validated at schema load time. |
| `max_entries`           | `integer`  | no       | `200`     | Maximum number of request/response pairs to keep in the ring buffer. When the buffer is full, the **oldest** entries are dropped so the most recent traffic is always retained. Hard upper bound: **10000**, validated at schema load time. |

## Behaviour

- **Additive.** Multiple `record_requests` steps extend the active URL
  pattern set. One step is the common case, but you can add patterns
  in later phases without replacing earlier ones.
- **Substring matching.** `url_matches` values are plain substring
  matches — `"bank.example/api/"` matches any URL containing that
  string. No regex, no glob, no eval. Keep the matching rules boring
  and predictable.
- **Base64 decoding.** Binary response bodies (where CDP returns
  `base64Encoded: true`) are decoded once at capture time. The decoded
  byte length is what `max_body_bytes` measures against.
- **Ring buffer.** Entries are stored in a ring buffer under
  `context[:debug_request_log]`. Overflow past `max_entries` drops
  the oldest entries, keeping the most recent traffic intact.
- **No JS injection.** This action does not inject JavaScript into the
  page. It uses only CDP `Network.*` event subscriptions.
- **Never in stage dumps.** The debug request log is excluded from
  `--dump-raw` / `--dump-normalized` output.

## Logging

The action logs:

```
[yml] record_requests: 2 pattern(s)
```

It never logs any matched URL, header name, header value, or body
content.

## Conditional execution

Like any step, `record_requests` supports
[`when_context`](workflow-when-context.md) gating:

```yaml
- action: record_requests
  url_matches: ["bank.example/api/"]
  include_response_body: true
  when_context:
    debug_mode:
      eq: true
```

## See also

- [`dump_requests`](workflow-action-dump-requests.md) — flush the recorded buffer to disk
- [Workflow Actions Reference](workflow-actions.md) — full action list
- [SECURITY.md](../SECURITY.md) — investigation tooling invariants
