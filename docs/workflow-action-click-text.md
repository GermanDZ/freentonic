# `click_text`

Clicks an element by its visible text content. Traverses shadow DOM
and same-origin iframes. Useful when the element has no stable CSS
selector but has predictable button/link text.

## Syntax

```yaml
- action: click_text
  text: "Buscar"
  role: "button"
  within: "#modal"
  match: "contains"
  timeout: 10
```

## Options

| Option    | Type      | Required | Default    | Description |
| --------- | --------- | -------- | ---------- | ----------- |
| `text`    | `string`  | **yes**  | —          | Text content to match against. Whitespace is normalized (collapsed to single spaces, trimmed). |
| `role`    | `string`  | no       | `"button"` | Element role filter. `"button"` matches `<button>` and `[role="button"]`. `"link"` matches `<a>` and `[role="link"]`. `"any"` matches any element. |
| `within`  | `string`  | no       | —          | CSS selector to scope the search. When set, only elements inside this container are considered. |
| `match`   | `string`  | no       | `"exact"`  | Matching strategy. `"exact"` requires full text match. `"contains"` matches if the element text includes the value. `"prefix"` matches if the element text starts with the value. |
| `timeout` | `integer` | no       | `10`       | Maximum seconds to wait for the element. Must be >= 1. |

## Behaviour

- Walks the DOM tree breadth-first, entering shadow roots and
  same-origin iframes.
- Focuses the element before clicking.
- Polls every 0.2 seconds until found or timeout.
- Logs `[yml] click_text: button "Buscar" (timeout: 10s) ✓` on success.
- Raises `UserError` on timeout, including the text and scope in the
  error message.

## Schema validation

- `text` must be a non-empty string.
- `role` must be one of `button`, `link`, `any`.
- `match` must be one of `exact`, `contains`, `prefix`.
- `timeout` must be a positive integer.

## See also

- [`click`](workflow-action-click.md) — click by CSS selector
- [Workflow Actions Reference](workflow-actions.md)
