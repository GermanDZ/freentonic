# `note`

Prints a message to stdout. Useful for labelling workflow sections
in the console output during development.

## Syntax

```yaml
- action: note
  message: "Starting login phase..."
```

## Options

| Option    | Type     | Required | Description |
| --------- | -------- | -------- | ----------- |
| `message` | `string` | **yes**  | Text to print, **verbatim**. `secret()` references are intentionally **not** resolved in notes — the message is printed as-is — so a note can never leak a resolved secret into the (persisted, host-visible) run log. |

## See also

- [Workflow Actions Reference](workflow-actions.md)
