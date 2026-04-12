# `wait_url`

Blocks until the current page URL contains a given substring. Useful
for waiting after login redirects or SPA navigation.

## Syntax

```yaml
- action: wait_url
  includes: /dashboard
  timeout: 60
```

## Options

| Option     | Type      | Required | Default | Description |
| ---------- | --------- | -------- | ------- | ----------- |
| `includes` | `string`  | **yes**  | —       | Substring that must appear in `window.location.href`. Supports `secret()` references. |
| `timeout`  | `integer` | no       | `30`    | Maximum seconds to wait before raising `UserError`. |

## Behaviour

- Polls every 0.2 seconds.
- Prints progress dots to stdout every 2 seconds while waiting.
- Raises `UserError` on timeout.

## See also

- [`navigate`](workflow-action-navigate.md) — navigate to a URL
- [`wait_for_selector`](workflow-action-wait-for-selector.md) — wait for a DOM element
- [Workflow Actions Reference](workflow-actions.md)
