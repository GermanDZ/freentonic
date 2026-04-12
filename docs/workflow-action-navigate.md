# `navigate`

Navigates Chrome to a URL.

## Syntax

```yaml
- action: navigate
  url: https://bank.example/login
```

## Options

| Option | Type     | Required | Description |
| ------ | -------- | -------- | ----------- |
| `url`  | `string` | **yes**  | Full URL to navigate to. Supports `secret()` references and `{context_key}` interpolation via the secret resolver. |

## Example

```yaml
- action: navigate
  url: https://bank.example/dashboard
```

## See also

- [`wait_url`](workflow-action-wait-url.md) — wait for navigation to complete
- [`reload`](workflow-action-reload.md) — reload the current page
- [Workflow Actions Reference](workflow-actions.md)
