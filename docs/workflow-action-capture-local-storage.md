# `capture_local_storage` / `capture_session_storage`

Snapshots `localStorage` (or `sessionStorage`) for a given security
origin into the workflow context. The bank's frontend parks
elevation-relevant state here — extended-session contexts, cached
access tokens, feature flags — that the headless extractor can't
reconstruct from outside the browser.

## Syntax

```yaml
- action: capture_local_storage
  origin: "https://bank.example.com"
  keys:                                  # optional allowlist
    - "ExtendedSessionContext"
    - "accessToken"
  as: bank_local_storage                 # → ctx.<as> (Hash)

- action: capture_session_storage
  origin: "https://bank.example.com"
  as: bank_session_storage
```

Both actions share the same option set — only the underlying CDP
storage type differs (`isLocalStorage: true` vs `false`).

## Options

| Option     | Type    | Required | Default | Description |
| ---------- | ------- | -------- | ------- | ----------- |
| `origin`   | string  | **yes**  | —       | Security origin (scheme + host + port) to snapshot from. Must match exactly what the browser used. |
| `as`       | string  | **yes**  | —       | Context key to store the resulting Hash under. |
| `keys`     | array   | no       | all keys | Allowlist of key names to include. Other keys are dropped. Missing keys are absent (not nil-filled). |
| `required` | boolean | no       | `true`  | When `true`, raises `UserError` if no entries (or no allowlisted keys) are returned. When `false`, leaves the context key unset and continues. |

## Behaviour

- Calls `DOMStorage.getDOMStorageItems` via CDP with the matching
  `isLocalStorage` flag.
- Filters against `keys:` when set.
- Stores the resulting Hash at `context["<as>"]`.
- Logs only the count of captured keys, never values — these are
  frequently JWTs, refresh tokens, or device-bound IDs.

## See also

- [`capture_cookie_header`](workflow-action-capture-cookie-header.md)
- [`elevate_session`](workflow-action-elevate-session.md) — typically runs before this
- [Workflow Actions Reference](workflow-actions.md)
