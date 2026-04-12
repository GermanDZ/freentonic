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
| `message` | `string` | **yes**  | Text to print. Supports `secret()` references (though you probably shouldn't put secrets in notes). |

## See also

- [Workflow Actions Reference](workflow-actions.md)
