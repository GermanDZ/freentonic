# `error_signals` — Early abort on screen errors

When a bank's anti-fraud system blocks a session, it typically displays an
error message or redirects to a block page. Without `error_signals`, the
workflow waits for the full timeout before failing with a generic
"timed out" error.

`error_signals` lets you define patterns that are checked during wait
loops. When a signal matches, the workflow immediately takes a screenshot
and aborts with a clear error message.

## Syntax

Add `error_signals` to the `config` section of your workflow YAML:

```yaml
config:
  key: unicaja
  error_signals:
    - text: "Ha ocurrido un error"
    - title: "Bloqueo Ciberseguridad"
    - selector: ".fraud-block-banner"
      message: "Bank fraud detection triggered"
```

## Signal types

| Key        | Description |
| ---------- | ----------- |
| `text`     | Matches if the page body contains the given substring |
| `title`    | Matches if the page title contains the given substring |
| `selector` | Matches if the CSS selector exists in the DOM |
| `message`  | Optional custom error message (defaults to the matched text/title/selector) |
| `kind`     | `"error"` (default) or `"reauth"` — see below |

Each signal must have at least one of `text`, `title`, or `selector`.

## `kind: reauth` — distinguishing re-authentication from hard errors

By default a matched signal raises `UserError` and the CLI exits with
status **1**. If the signal represents a session-level problem that the
user can resolve by logging in again (expired device trust, rotated MFA,
session idle-out), set `kind: reauth`:

```yaml
config:
  key: my_bank
  error_signals:
    - text: "session has expired"
      kind: reauth
      message: "bank session expired — log in again in the VNC window"
```

The runner then raises `ReauthRequired` (a subclass of `UserError`), and
the CLI exits with status **3**. The invoke server records this as
`error_kind: "needs_reauth"`, and the SimpleFIN bridge transitions the
profile into the `needs_reauth` state — surfacing a *Re-authenticate via
VNC* button to the operator instead of auto-retrying headlessly.

Use `kind: reauth` sparingly. Only use it for signals that unambiguously
mean "the user needs to log in again." Generic fraud-block screens
should remain the default `kind: error`.

## When are signals checked?

Signals are checked every ~2 seconds inside wait loops:

- `wait_for_selector`
- `wait_url`
- `wait_for_first_of`
- `wait_for_shadow_selector`

These are the natural points where an error could appear — the workflow
is already polling and the expected element or URL hasn't appeared yet.

Signals are **not** checked during instant actions (`click`, `fill`, etc.)
or fixed waits (`wait`, `wait_network_idle`).

## Behaviour on match

1. A screenshot is saved (same location as timeout screenshots).
2. The workflow aborts with: `Screen error detected: <message>`.
3. Chrome is closed and the process exits.

## Examples

### Spanish bank error page

```yaml
config:
  key: my_bank
  error_signals:
    - text: "Ha ocurrido un error"
    - title: "Bloqueo Ciberseguridad"
```

### Custom message

```yaml
config:
  key: my_bank
  error_signals:
    - selector: "#security-challenge"
      message: "Bank requires manual security challenge — run in VNC mode"
```

## Schema validation

- `error_signals` must be an array.
- Each entry must be a hash with at least one of `text`, `title`, or `selector`.
- A check that fails (e.g. page not yet loaded) is silently ignored — it
  will not interrupt the workflow.

## See also

- [Workflow Actions Reference](workflow-actions.md)
