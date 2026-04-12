# `capture_cookie_header`

Reads all cookies from Chrome, filters them by host and path using
RFC 6265 matching rules, formats them as a `Cookie` header string, and
stores the result in the workflow context.

## Syntax

```yaml
- action: capture_cookie_header
  host: bank.example
  path: /services/rest/
  as: cookie
  required: true
```

## Options

| Option     | Type      | Required | Default | Description |
| ---------- | --------- | -------- | ------- | ----------- |
| `host`     | `string`  | **yes**  | —       | Host to match cookies against. Uses RFC 6265 domain matching (`.example.com` covers `sub.example.com`). |
| `path`     | `string`  | **yes**  | —       | Path to match cookies against. Uses RFC 6265 path matching. |
| `as`       | `string`  | **yes**  | —       | Context key to store the Cookie header under. Also stores `<as>_cookie_count` with the number of matched cookies. |
| `required` | `boolean` | no       | `true`  | When `true`, raises `UserError` if no cookies match. When `false`, silently returns `nil`. |

## Behaviour

- Calls `Network.getAllCookies` via CDP to get the browser's full
  cookie jar.
- Filters by domain and path using `ChromeCdp.applicable_cookies`.
- Deduplicates cookies (longest path wins, then longest domain).
- Formats as `name1=value1; name2=value2`.
- Stores two context keys: `context["<as>"]` (the header string) and
  `context["<as>_cookie_count"]` (integer count).

## Example

```yaml
phases:
  capture_credentials:
    - action: wait_network_idle
      seconds: 3
    - action: capture_cookie_header
      host: bank.example
      path: /
      as: cookie
```

This produces `context["cookie"] = "sid=abc; token=xyz"` and
`context["cookie_cookie_count"] = 2`.

## See also

- [`capture_header`](workflow-action-capture-header.md) — capture an HTTP request header
- [Workflow Actions Reference](workflow-actions.md)
