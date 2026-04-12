# `pause`

Stops the workflow and waits for the user to press Enter. While paused,
the user can interact with Chrome manually — clicking around, navigating,
filling forms. If [`record_requests`](workflow-action-record-requests.md)
is active, all matching network traffic during the pause is captured
automatically.

**This action is for investigation during provider authoring only.**

## Syntax

```yaml
- action: pause
  message: "Navigate to the accounts page, then press Enter."
  timeout: 600
```

## Options

| Option    | Type      | Required | Default | Description |
| --------- | --------- | -------- | ------- | ----------- |
| `message` | `string`  | **yes**  | —       | Text shown to the user on stderr. Should describe what they need to do (or observe) before continuing. |
| `timeout` | `integer` | **yes**  | —       | Maximum seconds to wait for the user to press Enter. Must be >= 1. Enforced at schema load time. |

## Behaviour

- Prints `message` to stderr followed by `[press Enter to continue]`.
- Blocks on `stdin.gets` with the given timeout.
- Requires an interactive TTY — raises `UserError` if stdin is not a TTY.
- The user's input is discarded (they just press Enter).
- Logs `[yml] pause: resumed after Ns` to stdout. Does **not** log the
  message content.
- While paused, CDP Network events continue arriving on the WebSocket.
  They are drained on the next step after the pause resumes, so
  `record_requests` captures everything that happened during the pause.
- Does not inject JavaScript or touch the DOM.

## Schema validation

- `message` must be a non-empty string.
- `timeout` must be a positive integer.

## Composition patterns

### Manual exploration with network capture

```yaml
- action: record_requests
  url_matches: ["bank.example/api/"]
  include_response_body: true

- action: pause
  message: "Navigate to the page you want to investigate, then press Enter."
  timeout: 600

- action: dump_requests
  path: "/tmp/exploration.ndjson"
```

### Assisted login debugging

```yaml
- action: fill
  selector: "#user"
  value: "secret(USER_ID)"
- action: click
  selector: "#submit"

- action: record_requests
  url_matches: ["bank.example/"]
  include_response_body: true

- action: pause
  message: "Login submitted. Observe the redirect, then press Enter."
  timeout: 120

- action: capture_url
  as: post_login_url

- action: dump_requests
  path: "/tmp/post_login.ndjson"
```

## See also

- [`record_requests`](workflow-action-record-requests.md) — capture network traffic during the pause
- [`dump_requests`](workflow-action-dump-requests.md) — write the captured traffic to disk
- [`capture_url`](workflow-action-capture-url.md) — capture the current URL after manual navigation
- [`prompt_stdin_and_fill`](workflow-action-prompt-stdin-and-fill.md) — similar stdin pattern but fills a DOM input
- [Workflow Actions Reference](workflow-actions.md)
