# `wait_for_selector`

Blocks until a CSS selector exists in the DOM. The selector is resolved
through `deepQuery`, which traverses shadow roots and same-origin
iframes automatically.

## Syntax

```yaml
- action: wait_for_selector
  selector: "#dni"
  timeout: 15
```

## Options

| Option     | Type      | Required | Default | Description |
| ---------- | --------- | -------- | ------- | ----------- |
| `selector` | `string`  | **yes**  | —       | CSS selector to wait for. Traverses shadow DOM and iframes via `deepQuery`. |
| `timeout`  | `integer` | no       | `15`    | Maximum seconds to wait before raising `UserError`. |

## Behaviour

- Polls every 0.2 seconds.
- Prints progress dots every 2 seconds.
- Prints a checkmark on success.
- Raises `UserError` on timeout.

## See also

- [`wait_for_first_of`](workflow-action-wait-for-first-of.md) — wait for any of several selectors
- [`wait_for_shadow_selector`](workflow-action-wait-for-shadow-selector.md) — wait inside a specific shadow root
- [Workflow Actions Reference](workflow-actions.md)
