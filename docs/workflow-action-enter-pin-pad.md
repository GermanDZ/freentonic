# `enter_pin_pad`

Enters a PIN via a visual keypad widget (common in Spanish banks).
Reads the requested digit positions from the keypad's dots indicator,
maps them to the full PIN, and clicks the corresponding key buttons.

## Syntax

```yaml
- action: enter_pin_pad
  selector: ".container-pinpad"
  pin: "secret(USER_PIN)"
```

## Options

| Option     | Type     | Required | Description |
| ---------- | -------- | -------- | ----------- |
| `selector` | `string` | **yes**  | CSS selector for the pin pad container. Found via `deepQuery`. |
| `pin`      | `string` | **yes**  | Full PIN value. Supports `secret(NAME)` references. Non-digit characters are stripped. |

## Behaviour

- Waits up to ~9 seconds for the dots indicator (`.dots-indicator`) to
  report which PIN positions are requested.
- Reads positions from the indicator's `aria-label` attribute (e.g.
  "Position 1, 3, 5") or falls back to counting unfilled `.dot` elements.
- Clicks each digit button via its `aria-label` match, with random
  delay between clicks (300–700ms).
- Traverses shadow DOM and iframes via `deepQuery` + `findInTree`.
- Raises `UserError` if a requested position exceeds the PIN length.

## See also

- [`enter_digits`](workflow-action-enter-digits.md) — simpler digit entry without position mapping
- [`fill`](workflow-action-fill.md) — type into a regular input
- [Workflow Actions Reference](workflow-actions.md)
