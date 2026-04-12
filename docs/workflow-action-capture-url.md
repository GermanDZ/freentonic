# `capture_url`

Captures the current page URL (`window.location.href`) and stores it
in the workflow context. Useful during investigation to record where
you ended up after a redirect or manual navigation, and in production
for conditional logic based on which page the bank landed on.

## Syntax

```yaml
- action: capture_url
  as: current_page
```

## Options

| Option | Type     | Required | Description |
| ------ | -------- | -------- | ----------- |
| `as`   | `string` | **yes**  | Context key to store the URL under. Available to later steps via `{current_page}` interpolation or `when_context` gates. |

## Behaviour

- Evaluates `window.location.href` via `Runtime.evaluate`.
- Stores the result in `context["<as>"]`.
- Logs `[yml] capture_url: → ctx.<as>` to stdout. Does **not** log
  the URL itself (it may contain session tokens in query parameters).

## Example

### Log the post-login landing page

```yaml
- action: capture_url
  as: post_login_url

- action: note
  message: "Landed on: {post_login_url}"
```

### Conditional navigation based on current URL

```yaml
- action: capture_url
  as: current_page

- action: navigate
  url: https://bank.example/accounts
  when_context:
    current_page:
      neq: "https://bank.example/accounts"
```

### Combined with pause for investigation

```yaml
- action: pause
  message: "Navigate where you need to go, then press Enter."
  timeout: 300

- action: capture_url
  as: where_i_landed
```

## Schema validation

- `as` must be a non-empty string.

## See also

- [`pause`](workflow-action-pause.md) — let the user navigate manually before capturing
- [`capture_header`](workflow-action-capture-header.md) — capture an HTTP header value
- [`when_context`](workflow-when-context.md) — use the captured URL in conditional gates
- [Workflow Actions Reference](workflow-actions.md)
