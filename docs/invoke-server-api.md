# Invoke Server HTTP API

Reference for the HTTP API exposed by the freentonic invoke server.
For deployment and container setup, see
[invoke-server-deployment.md](invoke-server-deployment.md).

---

## At a glance

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/healthz` | Liveness probe. Always unauthenticated. |
| `GET` | `/status` | List in-flight invokes. Auth required if token is set. |
| `POST` | `/invoke` | Run one workflow end-to-end. Blocks until it finishes. |
| `POST` | `/cancel/{run_id}` | Best-effort SIGTERM to an in-flight invoke. |

Base URL on the host that runs the container: `http://127.0.0.1:7878`
(configurable via `FREENTONIC_LISTEN_PORT`). All responses are JSON
with `Content-Type: application/json`.

---

## Authentication

Set `FREENTONIC_INVOKE_TOKEN=<secret>` on the container at start.
Every authenticated request must include:

```
Authorization: Bearer <secret>
```

Missing or wrong token returns `401 Unauthorized` with body:

```json
{"error":"missing or invalid bearer token"}
```

`/healthz` is never authenticated — it's intended for readiness probes
and should work even if the caller doesn't have the token.

If `FREENTONIC_INVOKE_TOKEN` is unset, the server runs in OPEN mode
and logs a warning on startup. Acceptable for local development; not
for production.

---

## `POST /invoke`

Run one workflow. Blocks until the child process exits or the
`timeout_sec` elapses. Returns 200 with the exit code and artifact
list. A non-zero `exit_code` on 200 means the workflow ran but
something inside it failed — inspect the log referenced in the
response.

### Request body

```json
{
  "run_id":       "2026-04-21T12-34-56Z-abc123",
  "workflow":     "acme/workflow.yml",
  "profile_key":  "acme__tenant42",
  "credentials":  { "inline": { "USER_DNI": "...", "USER_PIN": "..." } },
  "export": {
    "mode":  "http",
    "url":   "http://host.docker.internal:3000/api/v1/bank_push",
    "token": "bearer-value-for-your-receiver",
    "method": "POST",
    "headers": { "X-Tenant": "42" }
  },
  "timeout_sec": 1800,
  "lookback":    14,
  "chrome":      { "isolated": false, "headless": false }
}
```

#### Fields

| Field | Required | Notes |
|---|---|---|
| `run_id` | yes | Caller-supplied identifier. Charset `[A-Za-z0-9_\-:.]{1,64}`. All per-run artifacts are namespaced under this id. Must be unique per in-flight invoke (409 on duplicate). |
| `workflow` | yes | Path to the workflow YAML, **relative to the container's workflows root** (`/home/freentonic/workflows` by default). Path-traversal attempts (`../`), symlinks escaping the root, or references to non-files return `404`. |
| `profile_key` | no | Identifies which Chrome profile subdirectory to use. Charset `[A-Za-z0-9_.\-]{1,128}`. **Strongly recommend** supplying an explicit, per-tenant value like `"acme__tenant42"`; otherwise the server derives one as `sha256(workflow + "\0" + credentials_fingerprint)[0..15]` which changes when credentials rotate, forcing a fresh login. |
| `credentials` | yes | Exactly one of `inline` (object of `KEY` → `VALUE`) or `file` (absolute path inside the container — useful when the caller has pre-managed a secrets file as a read-only bind mount). |
| `credentials.inline` | xor | Object. Keys must match `[A-Za-z_][A-Za-z0-9_.]*`; values cannot contain `\n` or `\0`. |
| `credentials.file` | xor | Absolute path inside the container. Must exist; should be mode `0600`. |
| `export` | no | Output configuration. If omitted, you must use a workflow that has a `--dump-raw`-equivalent — in practice always include this. |
| `export.mode` | yes *(within export)* | One of `http`, `json`, `jsonl`, `csv`. |
| `export.url` | if `mode=http` | Full receiver URL (include the path — `https://host/api/push`, not just `https://host`). |
| `export.token` | if `mode=http` | Bearer token for the receiver. Passed to the child via `FREENTONIC_HTTP_TOKEN` env var; never appears on argv or in logs. Pass an empty string (`""`) to explicitly opt out of sending an `Authorization` header. |
| `export.method` | no | `POST` (default) or `PUT`. |
| `export.content_type` | no | Default `application/json`. |
| `export.headers` | no | Extra request headers. Names match HTTP token charset; values cannot contain CRLF. |
| `export.path` | if `mode ∈ {json,jsonl,csv}` | Simple filename; written under `/workspace/runs/<run_id>/<path>` — the server rewrites it, so the caller can't escape the run dir. |
| `export.select` | no | Nested path for `csv`/`jsonl` flattening (e.g. `"accounts.movements"`). |
| `timeout_sec` | no | Default `1800`, max `7200`. Watchdog sends SIGTERM to the child's process group then SIGKILL after 10s grace. |
| `lookback` | no | Days of history to fetch. Overrides the workflow default. |
| `chrome.isolated` | no | If `true`, use a throwaway Chrome profile (ignores `profile_key`). Useful for debugging. |
| `chrome.headless` | no | Passes `--headless=new` to Chrome. Most banks detect and reject this; avoid unless you know the provider tolerates it. |

### Response — success (HTTP 200)

```json
{
  "run_id":      "2026-04-21T12-34-56Z-abc123",
  "exit_code":   0,
  "duration_ms": 12345,
  "artifacts": [
    { "path": "runs/2026-04-21T12-34-56Z-abc123/log", "size": 9412 },
    { "path": "runs/2026-04-21T12-34-56Z-abc123/2026-04-21T12-34-56Z-abc123-freentonic-timeout-20260421-123502-481.png", "size": 82411 }
  ],
  "log_path": "runs/2026-04-21T12-34-56Z-abc123/log",
  "warnings": []
}
```

- All `artifacts[].path` values are **relative to the host-side directory**
  you bind-mounted to `/workspace`. So if you mounted
  `-v ~/freentonic/runs:/workspace/runs`, the file is at
  `~/freentonic/runs/2026-04-21T12-34-56Z-abc123/log` on the host.
- `exit_code` is:
  - `0` — workflow completed successfully.
  - `1` — `UserError` in freentonic (bad YAML, missing secrets, validation
    failure, etc.). See the log.
  - `2` — `ExportError` (receiver rejected the payload, connection refused).
  - `128 + N` — child exited on signal N (e.g. `143` for SIGTERM, typically
    from `timeout_sec`).
- `duration_ms` is wall time from subprocess spawn to `Process.wait` return.
- `warnings` contains informational messages like `"timeout reached (...); child was terminated"`.

### Response — errors

| Status | Body `error` | When |
|---|---|---|
| `400` | `"invalid or missing JSON body"` | Body did not parse as JSON, or was empty. |
| `400` | `"... is required and must be a non-empty string"` | Required field missing. |
| `400` | `"... contains invalid characters or is too long"` | Charset/length violation. |
| `400` | `"export.url is required for mode=http"` etc. | Export block is malformed. |
| `400` | `"export.token is required for mode=http ..."` | `mode=http` with no token. Pass `""` to opt out of the `Authorization` header. |
| `401` | `"missing or invalid bearer token"` | Auth failure. |
| `404` | `"workflow not found: ..."` | Workflow path doesn't exist under the root. |
| `404` | `"workflow not found under workflows root"` | Path traversal (`..`, absolute path) blocked. |
| `404` | `"workflow resolves outside the workflows root"` | Symlink escape blocked. |
| `404` | `"workflow is not a regular file: ..."` | Path is a directory or special file. |
| `405` | `"method not allowed"` | Wrong HTTP method for the route. |
| `409` | `"run_id already in flight"` | A request with this `run_id` is still running. |
| `422` | `"credentials block is required"` | `credentials` absent. |
| `422` | `"credentials must contain exactly one of 'inline' or 'file'"` | Both provided or neither. |
| `422` | `"credentials.inline key ... is not a valid identifier"` | Key charset violation. |
| `422` | `"credentials.inline value for ... contains a forbidden character"` | Value contains `\n` or `\0`. |
| `422` | `"credentials.file does not exist: ..."` | Bound file not accessible. |
| `413` | `"payload too large"` | Body exceeded 1 MiB. |
| `500` | `"<Exception class>: <message>"` | Unhandled server error. Check container logs. |
| `503` | `"server shutting down"` | SIGTERM received; no new invokes accepted. |

### Concurrency contract

- **v1 is strictly serialized.** Two simultaneous `POST /invoke` calls
  do not run in parallel; the second blocks inside the server until the
  first returns. Plan your web-app retry behavior with this in mind
  (use a worker pool with `concurrency=1` per freentonic container).
- **Duplicate `run_id` while in-flight → 409.** Once the original
  finishes and is removed from the in-flight registry, the same `run_id`
  can be reused — but we recommend not reusing ids, to keep artifact
  history clean.
- **Connections block for the full invoke duration.** Set your HTTP
  client's read-timeout to at least `timeout_sec + 30 seconds`.

---

## `GET /healthz`

Liveness probe. **No authentication**. Useful for container readiness
checks and load-balancer health monitoring.

```sh
curl -sS http://127.0.0.1:7878/healthz
```

Response (HTTP 200):

```json
{"ok":true,"in_flight":0,"shutting_down":false}
```

`in_flight` is `0` or `1` given v1 serialization. `shutting_down`
flips to `true` after SIGTERM.

---

## `GET /status`

Inspect the in-flight invoke (0 or 1 given serialization).
**Auth required** (if the server has a token set).

```sh
curl -sS -H "Authorization: Bearer $FREENTONIC_INVOKE_TOKEN" \
  http://127.0.0.1:7878/status
```

Response (HTTP 200):

```json
{
  "in_flight": [
    {
      "run_id":      "2026-04-21T12-34-56Z-abc123",
      "profile_key": "acme__tenant42",
      "started_at":  "2026-04-21T12:34:56+00:00",
      "elapsed_ms":  4812
    }
  ]
}
```

The array is empty when the server is idle.

---

## `POST /cancel/{run_id}`

Best-effort cancellation. Sends SIGTERM to the child's process group,
then SIGKILL after 10 seconds if the child is still alive.
**Auth required.**

```sh
curl -sS -X POST \
  -H "Authorization: Bearer $FREENTONIC_INVOKE_TOKEN" \
  http://127.0.0.1:7878/cancel/2026-04-21T12-34-56Z-abc123
```

Response (HTTP 202):

```json
{"accepted":true,"run_id":"2026-04-21T12-34-56Z-abc123"}
```

Cancellation does not interrupt the already-blocking `POST /invoke`
call — the server returns from `/invoke` normally (with a non-zero
`exit_code`) once the child dies. The `/cancel` endpoint simply makes
that happen sooner.

If the run id is unknown or the child hasn't been spawned yet
(extremely brief window between registration and spawn), you get
`404 {"error":"run_id not in flight or not yet spawned"}`.

---

## Artifact retrieval

The server writes per-run artifacts under `/workspace/runs/<run_id>/`,
which is bind-mounted to your chosen host directory. Typical contents:

```
~/freentonic/runs/2026-04-21T12-34-56Z-abc123/
  log                                                              ← merged stdout+stderr
  2026-04-21T12-34-56Z-abc123-freentonic-login-20260421-123457-123.png
  2026-04-21T12-34-56Z-abc123-freentonic-timeout-20260421-123502-481.png
  movements.csv                                                    ← if export.mode=csv
```

Filenames:

- **`log`** — always present; merged stdout+stderr of the child freentonic process.
- **`<run_id>-freentonic-<label>-<YYYYMMDD-HHMMSS-mmm>.png`** — screenshots
  saved by the workflow. The `<label>` describes the reason: `login`,
  `timeout`, `error-signal`, or any custom label from a `screenshot:` action
  in the workflow YAML.
- **Exporter output** — whatever filename you passed as `export.path`,
  placed under the run dir.

Your web app should enumerate this directory (it's on the host
filesystem) and attach or index the files as it sees fit. The server
never deletes them; implement retention in the web app.

---

## Caller examples

### curl

```sh
TOKEN=$(cat ~/.freentonic-invoke-token)
curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data @- \
  http://127.0.0.1:7878/invoke <<'JSON'
{
  "run_id": "adhoc-$(date +%s)",
  "workflow": "ing/workflow.yml",
  "profile_key": "ing__owner42",
  "credentials": {
    "inline": {
      "USER_DNI": "12345678A",
      "USER_PIN": "123456"
    }
  },
  "export": {
    "mode": "http",
    "url": "http://host.docker.internal:3000/api/v1/bank_push",
    "token": "your-receiver-token"
  },
  "timeout_sec": 900
}
JSON
```

### Ruby (stdlib, no gems)

```ruby
require "net/http"
require "json"
require "uri"

uri = URI("http://127.0.0.1:7878/invoke")
req = Net::HTTP::Post.new(uri)
req["Authorization"] = "Bearer #{ENV.fetch('FREENTONIC_INVOKE_TOKEN')}"
req["Content-Type"]  = "application/json"
req.body = JSON.generate(
  run_id: "owner42-ing-#{Time.now.to_i}",
  workflow: "ing/workflow.yml",
  profile_key: "ing__owner42",
  credentials: { inline: { USER_DNI: "12345678A", USER_PIN: "123456" } },
  export: {
    mode: "http",
    url: "http://host.docker.internal:3000/api/v1/bank_push",
    token: ENV.fetch("RECEIVER_TOKEN")
  },
  timeout_sec: 900
)

http = Net::HTTP.new(uri.host, uri.port)
http.read_timeout = 950  # must exceed timeout_sec + grace
res = http.request(req)

raise "invoke failed: #{res.code} #{res.body}" unless res.code.to_i == 200
result = JSON.parse(res.body)
puts "exit=#{result["exit_code"]} duration=#{result["duration_ms"]}ms"
puts "log: #{result["log_path"]}"
```

### Python (requests)

```python
import os, time, requests

token = os.environ["FREENTONIC_INVOKE_TOKEN"]
receiver_token = os.environ["RECEIVER_TOKEN"]

resp = requests.post(
    "http://127.0.0.1:7878/invoke",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "run_id": f"owner42-ing-{int(time.time())}",
        "workflow": "ing/workflow.yml",
        "profile_key": "ing__owner42",
        "credentials": {"inline": {"USER_DNI": "12345678A", "USER_PIN": "123456"}},
        "export": {
            "mode": "http",
            "url": "http://host.docker.internal:3000/api/v1/bank_push",
            "token": receiver_token,
        },
        "timeout_sec": 900,
    },
    timeout=(10, 950),   # (connect, read)
)
resp.raise_for_status()
print(resp.json())
```

### Node.js (fetch)

```js
const token = process.env.FREENTONIC_INVOKE_TOKEN;

const res = await fetch("http://127.0.0.1:7878/invoke", {
  method: "POST",
  headers: {
    "Authorization": `Bearer ${token}`,
    "Content-Type":  "application/json",
  },
  body: JSON.stringify({
    run_id:       `owner42-ing-${Date.now()}`,
    workflow:     "ing/workflow.yml",
    profile_key:  "ing__owner42",
    credentials:  { inline: { USER_DNI: "12345678A", USER_PIN: "123456" } },
    export: {
      mode:  "http",
      url:   "http://host.docker.internal:3000/api/v1/bank_push",
      token: process.env.RECEIVER_TOKEN,
    },
    timeout_sec: 900,
  }),
  // Node's default fetch has no built-in body read-timeout; wrap in AbortController
  // with a duration > timeout_sec if you need one.
});

if (!res.ok) throw new Error(`invoke failed: ${res.status} ${await res.text()}`);
console.log(await res.json());
```

---

## End-to-end flow from a web app

1. **User clicks "sync" in your web app for provider `ing`, owner 42.**
2. Web app computes `run_id` (e.g. `owner42-ing-$(uuid)`) and
   `profile_key` (e.g. `ing__owner42`).
3. Web app POSTs to `/invoke`. The HTTP call blocks — expect it to
   take seconds to minutes depending on the provider.
4. Response comes back with `exit_code` and `artifacts`.
5. Web app enumerates `<runs_dir>/<run_id>/` to attach the log and
   any screenshots to the sync record in its own database.
6. If `exit_code != 0`, web app surfaces the last 10 lines of the log
   to the user and offers a retry button.
7. **User retries.** Web app generates a fresh `run_id`, keeps the
   same `profile_key` so Chrome reuses the existing login. POSTs again.

### Tips

- **Always include `profile_key`**. The derived default changes when
  credentials change, which invalidates the cached login.
- **Pick a `run_id` scheme you can sort and grep.** `{tenant}-{provider}-{iso8601}-{nonce}`
  is a good shape.
- **Consider a job queue (Sidekiq, RQ, etc.)** in your web app that
  serializes requests per freentonic container — since v1 is
  serialized, sending many concurrent invokes just creates connection
  queue depth without throughput gain.
- **Set your HTTP client's read-timeout > `timeout_sec + 30`** to
  avoid premature disconnects.
- **Use `/status`** in an internal ops view; users never need to see it.

---

## What's NOT in v1

- Parallelism (planned: per-`profile_key` mutex + subprocess port/display pools).
- Log streaming (`/logs/{run_id}` SSE). Today the log file is written
  during the run, so the web app can `tail -f` it on the host directly.
- Metrics endpoint (`/metrics` Prometheus-style).
- Retry/backoff built into `/invoke`. Handle retries in the web app.
- Per-user sockets / multi-tenant auth. One token, one server.

See the plan file for the full follow-up list.
