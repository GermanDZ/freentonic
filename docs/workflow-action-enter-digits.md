# `enter_digits`

Clicks digit buttons on a keypad one by one. Unlike
[`enter_pin_pad`](workflow-action-enter-pin-pad.md), this does not read
position indicators — it simply clicks each digit in the given order.

## Syntax

```yaml
- action: enter_digits
  keypad: "#pin_pad"
  digits:
    - "secret(PIN_DIGIT_1)"
    - "secret(PIN_DIGIT_2)"
    - "secret(PIN_DIGIT_3)"
```

## Options

| Option   | Type              | Required | Description |
| -------- | ----------------- | -------- | ----------- |
| `keypad` | `string`          | **yes**  | CSS selector for the keypad container. Buttons inside this container are searched for matching digit text or `data-digit` attribute. |
| `digits` | `string[]`        | **yes**  | Array of digit values to click, in order. Each value supports `secret(NAME)` references. |

## Behaviour

- For each digit, searches within the keypad container for buttons
  (`button`, `[role='button']`, `a`, `input[type='button']`,
  `input[type='submit']`, `[data-digit]`) whose `data-digit`, `value`,
  `innerText`, or `textContent` matches the digit string.
- Clicks the first match found.
- Waits 0.2 seconds between digits.
- Raises `UserError` if a digit button is not found.

## See also

- [`enter_pin_pad`](workflow-action-enter-pin-pad.md) — position-aware PIN entry
- [Workflow Actions Reference](workflow-actions.md)
