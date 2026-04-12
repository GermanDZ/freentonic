# `wait_for_first_of`

Blocks until any of the given CSS selectors exists in the DOM. Useful
when a page may land on one of several possible states (e.g. OTP
challenge vs. dashboard redirect).

## Syntax

```yaml
- action: wait_for_first_of
  selectors:
    - "#dashboard"
    - "input[name='otp']"
  timeout: 30
```

## Options

| Option      | Type       | Required | Default | Description |
| ----------- | ---------- | -------- | ------- | ----------- |
| `selectors` | `string[]` | **yes**  | —       | Array of CSS selectors. Returns as soon as any one is found via `deepQuery`. |
| `timeout`   | `integer`  | no       | `30`    | Maximum seconds to wait before raising `UserError`. |

## Behaviour

- Polls every 0.2 seconds, checking each selector in order.
- Prints progress dots every 2 seconds.
- Returns as soon as the first match is found.
- Raises `UserError` on timeout.

## See also

- [`wait_for_selector`](workflow-action-wait-for-selector.md) — wait for a single selector
- [Workflow Actions Reference](workflow-actions.md)
