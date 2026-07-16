# `inspect_page`

Observes the live page as **structured text, not pixels**: the URL, the
title, and an inventory of the visible interactive elements (`a`,
`button`, `input`, `select`, `[role=button]`). Each element carries a
YAML-ready selector candidate, the heuristic that produced it, a
`needs_review` flag, and — for inputs — a `type`, a best-effort `label`,
and a `masked` boolean.

This is the machine-readable counterpart to `screenshot`. It is meant
for the authoring/observe-act-observe loop: after a step runs you can ask
"what can I click now, and what selector should I use?" without diffing
PNGs.

> **Element values are never surfaced.** The inventory reports whether an
> input *is* sensitive (`masked: true`) but never its contents. Even a
> non-sensitive input's typed value is dropped. See
> [SECURITY.md](../SECURITY.md).

## Syntax

```yaml
- action: inspect_page
  as: page   # optional
```

## Options

| Option | Type     | Required | Description |
| ------ | -------- | -------- | ----------- |
| `as`   | `string` | no       | Context key to store the inventory hash under. Omit to log the element count only (handy for a quick sanity check). |

## Result shape

When `as:` is given, `context["<as>"]` holds:

```jsonc
{
  "url": "https://bank.example/login",
  "title": "Login",
  "interactive": [
    { "tag": "input", "selector": "#dni", "selector_strategy": "id",
      "needs_review": false, "type": "text", "label": "DNI", "masked": false },
    { "tag": "input", "selector": "#pwd", "selector_strategy": "id",
      "needs_review": false, "type": "password", "label": "Password", "masked": true },
    { "tag": "button", "selector": "#submit", "selector_strategy": "id",
      "needs_review": false, "text": "Entrar" }
  ]
}
```

## Behaviour

- Runs a single `Runtime.evaluate` that walks the DOM, piercing shadow
  roots and same-origin iframes (the same `deepQuery` traversal the
  selector actions use).
- Reuses the recorder's selector heuristics, so the selector it suggests
  matches what a recording would have captured for the same element.
- Logs `[yml] inspect_page: N interactive element(s)` to stdout — a
  **count only**, never selectors, labels, or values.
- Stores the inventory in `context["<as>"]` when `as:` is present.

## Example

```yaml
- action: navigate
  url: https://bank.example/login

- action: inspect_page
  as: login_page

- action: note
  message: "Login page has interactive elements to choose a selector from."
```

## Schema validation

- `as`, if present, must be a string.

## See also

- [`screenshot`](workflow-actions.md) — the pixel counterpart
- [`capture_url`](workflow-action-capture-url.md) — capture just the URL
- [SECURITY.md](../SECURITY.md) — why the inventory (and `failures.ndjson`) carry metadata, never values
- [Workflow Actions Reference](workflow-actions.md)
