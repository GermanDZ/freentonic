# `prompt_stdin_and_fill`

Reads a one-shot value (SMS OTP, email code, etc.) from the terminal
and types it into a DOM input. The value is never stored in a secret
backend, never written to logs, and never placed on the context — it
exists only for the duration of this single fill.

## Syntax

```yaml
- action: prompt_stdin_and_fill
  selector: "input[name='otp']"
  prompt: "Enter the SMS code: "
  timeout: 300
  submit_selector: "button[type='submit']"
  mask: false
  if_present: true
```

## Options

| Option             | Type      | Required | Default | Description |
| ------------------ | --------- | -------- | ------- | ----------- |
| `selector`         | `string`  | **yes**  | —       | CSS selector for the input to fill. Found via `deepQuery`. |
| `prompt`           | `string`  | **yes**  | —       | Text shown to the user on stderr before reading input. |
| `timeout`          | `integer` | **yes**  | —       | Maximum seconds to wait for user input. Must be >= 1. Validated at schema load time. |
| `submit_selector`  | `string`  | no       | —       | CSS selector for a submit button to click after filling. |
| `mask`             | `boolean` | no       | `false` | When `true`, uses `IO.console.getpass` (no echo) instead of regular `gets`. |
| `if_present`       | `boolean` | no       | `false` | When `true`, checks if the selector exists in the DOM first. If absent, the step is silently skipped — the terminal is never prompted. |

## Behaviour

- When stdin is a TTY: prints the prompt to stderr and reads one line
  from stdin (CLI mode).
- When stdin is not a TTY but `FREENTONIC_RUN_DIR` is set (which the
  invoke server populates automatically): falls back to the [remote
  prompt protocol](invoke-server-api.md#get-runsrun_idprompts-and-post-runsrun_idpromptsprompt_id).
  The runner writes a request file under `<run_dir>/prompts/`; an HTTP
  client discovers it via `GET /runs/{run_id}/prompts` and submits the
  value via `POST /runs/{run_id}/prompts/{prompt_id}`. Same YAML, no
  changes needed for server vs. CLI.
- When neither a TTY nor `FREENTONIC_RUN_DIR` is available, raises
  `UserError` (prevents silently consuming piped input).
- Raises `UserError` if the input is empty or the timeout expires.
- Types the value using the same CDP keystroke simulation as
  [`fill`](workflow-action-fill.md) — never interpolated into JS.
- If `submit_selector` is set, clicks that element after filling.
- Logs `[yml] prompt_stdin_and_fill: filled <selector>` — never logs
  the captured value or its length. In server mode, also emits one
  `[freentonic][prompt] {…json…}` advisory line on stderr so humans
  tailing the log see why the run paused; that line never contains
  the value.

## Schema validation

- `selector` must be a non-empty string.
- `prompt` must be a non-empty string.
- `timeout` must be a positive integer.
- `submit_selector`, if present, must be a string.
- `mask` and `if_present`, if present, must be boolean.

## Security

The captured value is:
- Never written to logs (not the value, not its length).
- Never stored in the secret backend.
- Never placed on `@context`.
- Never resolved through `secret()`.
- Fed into the page through CDP key events, never string-interpolated
  into JavaScript.

See [SECURITY.md](../SECURITY.md) for full details.

## Example

```yaml
phases:
  login:
    - action: navigate
      url: https://bank.example/login
    - action: fill
      selector: "#dni"
      value: "secret(USER_DNI)"
    - action: enter_pin_pad
      selector: ".container-pinpad"
      pin: "secret(USER_PIN)"
    # Handle SMS OTP — skipped if the bank doesn't challenge:
    - action: prompt_stdin_and_fill
      selector: "input[name='otp']"
      prompt: "Enter the SMS code: "
      timeout: 300
      submit_selector: "button[type='submit']"
      if_present: true
    - action: wait_url
      includes: /dashboard
```

## See also

- [`fill`](workflow-action-fill.md) — type a pre-known value
- [Workflow Actions Reference](workflow-actions.md)
