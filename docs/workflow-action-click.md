# `click` / `click_if_present`

Clicks an element matched by a CSS selector. `click` raises if the
element is not found; `click_if_present` silently does nothing.

## Syntax

```yaml
# Required — raises if not found:
- action: click
  selector: "button[type='submit']"

# Optional — no-op if absent:
- action: click_if_present
  selector: "#cookie-banner .dismiss"
```

## Options

| Option     | Type     | Required | Description |
| ---------- | -------- | -------- | ----------- |
| `selector` | `string` | **yes**  | CSS selector. Found via `deepQuery` (traverses shadow DOM and iframes). |

## Behaviour

- Blurs the currently focused element before clicking (prevents
  stale-focus issues on SPAs).
- Uses `deepQuery` to find the element through shadow roots and
  same-origin iframes.
- `click` raises `UserError` if the selector is not found.
- `click_if_present` returns silently if not found.

## See also

- [`click_text`](workflow-action-click-text.md) — click by visible text instead of selector
- [`fill`](workflow-action-fill.md) — type into a form input
- [Workflow Actions Reference](workflow-actions.md)
