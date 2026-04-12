# `fill` / `fill_if_present`

Types text into a form input, simulating human keystroke timing.
`fill` raises if the input is not found; `fill_if_present` silently
does nothing.

## Syntax

```yaml
# Required — raises if not found:
- action: fill
  selector: "#dni"
  value: "secret(USER_DNI)"
  clear: true

# Optional — no-op if absent:
- action: fill_if_present
  selector: "#optional-field"
  value: "some value"
```

## Options

| Option     | Type      | Required | Default | Description |
| ---------- | --------- | -------- | ------- | ----------- |
| `selector` | `string`  | **yes**  | —       | CSS selector for the input element. Found via `deepQuery`. |
| `value`    | `string`  | **yes**  | —       | Text to type. Supports `secret(NAME)` references. |
| `clear`    | `boolean` | no       | `false` | When `true`, clears the input's current value before typing by setting `value = ""` and dispatching `input` + `change` events. Only works on `<input>` and `<textarea>` — raises `UserError` on other elements. |

## Behaviour

- Finds the element via `deepQuery`, focuses it, and clicks it.
- Types each character one at a time via CDP `Input.dispatchKeyEvent`
  with variable inter-keystroke delay (40–130ms) to appear human.
- After typing, simulates a Tab keypress to move focus away, triggering
  any validation-on-blur handlers.
- When `clear: true`, the existing value is cleared programmatically
  before typing. This dispatches `input` and `change` events so
  React/Angular bindings update.

## Schema validation

- `clear` must be `true` or `false` (not a string like `"yes"`).

## See also

- [`click`](workflow-action-click.md) — click without typing
- [`prompt_stdin_and_fill`](workflow-action-prompt-stdin-and-fill.md) — read a value from the terminal
- [`enter_pin_pad`](workflow-action-enter-pin-pad.md) — enter a PIN via visual keypad
- [Workflow Actions Reference](workflow-actions.md)
