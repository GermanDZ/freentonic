# `wait_network_idle`

Drains CDP events for a given number of seconds. This lets the browser
finish in-flight requests and ensures pending network events are
available for subsequent capture actions.

## Syntax

```yaml
- action: wait_network_idle
  seconds: 3
```

## Options

| Option    | Type      | Required | Default | Description |
| --------- | --------- | -------- | ------- | ----------- |
| `seconds` | `integer` | no       | `3`     | Number of seconds to drain events. The session drainer runs one iteration per second. |

## Behaviour

Uses the `session_drainer` callback, which reads and buffers CDP events
without blocking on any specific event type. Place this before
`capture_header` or `capture_cookie_header` to ensure network events
have been received.

## See also

- [`capture_header`](workflow-action-capture-header.md)
- [`capture_cookie_header`](workflow-action-capture-cookie-header.md)
- [Workflow Actions Reference](workflow-actions.md)
