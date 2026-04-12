# `dump_requests`

Flushes the current recording buffer (populated by
[`record_requests`](workflow-action-record-requests.md)) to a file on
disk. Place it at the end of a phase so the file exists even if a
later step fails.

**This action is for investigation during provider authoring only. Never
ship it in a production workflow.** See [SECURITY.md](../SECURITY.md)
for the full invariants.

## Syntax

```yaml
- action: dump_requests
  path: "/tmp/bank_capture.json"
  format: "ndjson"
  reset: true
```

## Options

| Option   | Type      | Required | Default    | Description |
| -------- | --------- | -------- | ---------- | ----------- |
| `path`   | `string`  | **yes**  | —          | Output file path. Resolved via `File.expand_path` at runtime, so relative paths work from your CWD. **Must be outside** your git repo and outside any directory named `freentonic-providers` — a safety check to reduce the odds of accidentally committing captures. |
| `format` | `string`  | no       | `"ndjson"` | Output format. `"ndjson"` writes one JSON object per line. `"har"` writes a minimal-but-valid HAR 1.2 file. See [Output formats](#output-formats) below. |
| `reset`  | `boolean` | no       | `false`    | When `true`, clears the in-memory ring buffer after writing. Useful for splitting captures by phase — record during login, dump, reset, record during navigation, dump again. |

## Output formats

### `ndjson` (default)

One JSON object per line. Greppable, diffable, streamable. Each line
has the shape:

```json
{
  "request": {
    "method": "GET",
    "url": "https://bank.example/api/accounts",
    "headers": {"Cookie": "sid=abc", ...},
    "body": null
  },
  "response": {
    "status": 200,
    "headers": {"Content-Type": "application/json", ...},
    "body": "{\"accounts\":[]}",
    "truncated": false
  },
  "timings": {
    "started_at": "2026-01-15T10:00:00+00:00",
    "duration_ms": 120
  }
}
```

- `response.body` is present only if `include_response_body: true` was
  set on the corresponding `record_requests` step.
- `response.truncated` is `true` when the body was larger than
  `max_body_bytes` and was cut short.

Useful commands for inspecting ndjson captures:

```sh
# List all unique API URLs:
jq -r '.request.url' /tmp/capture.ndjson | sort -u

# Find response fields for a specific endpoint:
grep 'movements' /tmp/capture.ndjson | jq '.response.body | fromjson'

# Count requests per URL pattern:
jq -r '.request.url' /tmp/capture.ndjson | grep -oP '/api/[^?]+' | sort | uniq -c | sort -rn
```

### `har`

Minimal HAR 1.2 file. Importable by Chrome DevTools (Network tab >
Import HAR file) and every HAR viewer in the world.

The writer emits only the fields needed for human/agent inspection:
request method/URL/headers, response status/headers/content, and page
timing stubs. It does not emit optional HAR fields that add no value
for investigation.

```sh
# Import into Chrome: open DevTools → Network → Import HAR file
# Or use a CLI HAR viewer
```

## Behaviour

- **Internal keys stripped.** Entries in the in-memory buffer carry
  internal tracking keys (prefixed with `_`). These are removed before
  writing to disk.
- **Empty buffer.** If no `record_requests` step has run (or the buffer
  was reset), an empty file is written.
- **Path safety.** The path is validated at runtime. Paths containing
  `freentonic-providers` or resolving inside the current git repo are
  rejected with a `UserError`.

## Logging

The action logs:

```
[yml] dump_requests: wrote 42 entries to /tmp/bank_capture.ndjson
```

It never logs any URL, header, or body content from the captured
entries.

## Full example

See the [investigation example](workflow-action-record-requests.md) in
the `record_requests` docs, or the commented-out `investigate` phase in
[examples/example_bank.yml](../examples/example_bank.yml).

A typical workflow during provider authoring:

```yaml
pipeline: [login, capture_credentials, investigate]

phases:
  # ... login and capture_credentials as usual ...

  investigate:
    - action: record_requests
      url_matches:
        - "bank.example/apis/"
      include_response_body: true
      max_body_bytes: 131072

    - action: navigate
      url: https://bank.example/accounts
    - action: wait_network_idle
      seconds: 5

    - action: dump_requests
      path: "/tmp/bank_capture.ndjson"
      format: "ndjson"
      reset: true

    # Navigate somewhere else and capture a second batch:
    - action: navigate
      url: https://bank.example/transfers
    - action: wait_network_idle
      seconds: 5

    - action: dump_requests
      path: "/tmp/bank_transfers.ndjson"
      format: "ndjson"
```

Remove the `investigate` phase and its pipeline entry before committing
your provider.

## See also

- [`record_requests`](workflow-action-record-requests.md) — start recording
- [Workflow Actions Reference](workflow-actions.md) — full action list
- [SECURITY.md](../SECURITY.md) — investigation tooling invariants
