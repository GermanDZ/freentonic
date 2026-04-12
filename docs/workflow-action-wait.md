# `wait`

Sleeps for a fixed number of seconds. Use this when you need a hard
delay — prefer [`wait_network_idle`](workflow-action-wait-network-idle.md)
or [`wait_for_selector`](workflow-action-wait-for-selector.md) when you
can wait for a signal instead.

## Syntax

```yaml
- action: wait
  seconds: 3
```

## Options

| Option    | Type     | Required | Description |
| --------- | -------- | -------- | ----------- |
| `seconds` | `number` | **yes**  | Number of seconds to sleep. Can be an integer or float. |

## See also

- [`wait_url`](workflow-action-wait-url.md)
- [`wait_network_idle`](workflow-action-wait-network-idle.md)
- [`wait_for_selector`](workflow-action-wait-for-selector.md)
- [Workflow Actions Reference](workflow-actions.md)
