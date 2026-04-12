# `wait_for_shadow_selector`

Blocks until a CSS selector exists inside a specific custom element's
shadow root. Use this when `deepQuery` traversal is too broad and you
need to target a known shadow host.

## Syntax

```yaml
- action: wait_for_shadow_selector
  host: "my-component"
  selector: ".inner-button"
  timeout: 30
```

## Options

| Option     | Type      | Required | Default | Description |
| ---------- | --------- | -------- | ------- | ----------- |
| `host`     | `string`  | **yes**  | —       | CSS selector for the shadow host element. Found via `deepQuery`. |
| `selector` | `string`  | **yes**  | —       | CSS selector to find inside the host's `shadowRoot`. |
| `timeout`  | `integer` | no       | `30`    | Maximum seconds to wait before raising `UserError`. |

## Behaviour

- Finds the host element via `deepQuery`, then queries its `shadowRoot`.
- Polls every 0.2 seconds.
- Raises `UserError` on timeout.

## See also

- [`wait_for_selector`](workflow-action-wait-for-selector.md) — simpler wait using `deepQuery` traversal
- [Workflow Actions Reference](workflow-actions.md)
