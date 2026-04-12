# `when_context` — Conditional step execution

Any workflow step can include a `when_context` gate to run conditionally
based on runtime context values. When the condition is not met, the step
is silently skipped with a log message.

## Syntax

```yaml
- action: navigate
  url: https://bank.example/history
  when_context:
    lookback_days:
      gt: 30
    isolated:
      eq: true
```

## Structure

`when_context` is a hash where:
- **Keys** are context variable names (checked against both runtime
  context and workflow context).
- **Values** are hashes of `operator: operand` pairs.
- All keys are ANDed — every key must pass.
- All operators within a key are ANDed — every operator must pass.

## Operators

| Operator  | Operand type | Description |
| --------- | ------------ | ----------- |
| `gt`      | `numeric`    | Greater than |
| `gte`     | `numeric`    | Greater than or equal to |
| `lt`      | `numeric`    | Less than |
| `lte`     | `numeric`    | Less than or equal to |
| `eq`      | any          | Equal (strict `==`) |
| `neq`     | any          | Not equal |
| `present` | `boolean`    | `true` means the key must exist (non-nil). `false` means the key must be nil. |
| `absent`  | `boolean`    | Inverse of `present`. `true` means the key must be nil. |

## Context resolution order

1. Runtime context (`:symbol` keys, then `"string"` keys) — values
   passed at invocation time (e.g. `lookback_days`, `isolated`).
2. Workflow context (`"string"` keys) — values captured during the
   workflow run (e.g. from `capture_header`).

A missing key resolves to `nil`.

## Schema validation

- `when_context` must be a hash.
- Each key must map to a non-empty hash of operators.
- Operators must be one of the recognized set.
- Numeric operators (`gt`, `gte`, `lt`, `lte`) require a numeric operand.
- Presence operators (`present`, `absent`) require a boolean operand.

## Examples

### Skip a step when lookback is short

```yaml
- action: navigate
  url: https://bank.example/full-history
  when_context:
    lookback_days:
      gt: 90
```

### Combine multiple conditions

```yaml
- action: fill
  selector: "#device-id"
  value: "secret(DEVICE_ID)"
  when_context:
    device_id:
      present: true
    isolated:
      eq: false
```

### Range check

```yaml
- action: navigate
  url: https://bank.example/paginated-history
  when_context:
    lookback_days:
      gte: 30
      lte: 365
```

## Logging

When a step is skipped:

```
[yml] skipped (when_context): navigate
```

## See also

- [Workflow Actions Reference](workflow-actions.md)
