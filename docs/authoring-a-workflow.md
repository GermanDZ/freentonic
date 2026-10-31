# Authoring a new workflow

Building (or repairing) a provider means driving a bank's real UI by hand —
recording the login, watching which API call carries the data — while
iterating on a YAML draft. Freentonic ships a set of **discovery tools** that
turn that into a tight loop: bootstrap → record → compile → review → lint →
step → capture. This guide walks the loop end to end.

It pairs with two other docs:

- **[authoring-in-docker.md](authoring-in-docker.md)** — the `author`
  container the loop runs in (writable workspace + noVNC). Recommended
  environment; everything below runs the same locally if you have Chrome.
- The **[Workflow YAML reference](../README.md#workflow-yaml-reference)** and
  the per-action docs (`docs/workflow-action-*.md`) — the vocabulary the
  drafts are written in.

The whole action dialect, machine-readable, is `freentonic --schema-json`
(no Chrome, no workflow) — the reference for what's legal in a workflow, and
the system-prompt payload for an authoring agent.

---

## The loop at a glance

| Step | Command | Produces |
| --- | --- | --- |
| 1. Bootstrap | `freentonic --init` | a stub `workflow.yml` |
| 2. Record | `freentonic --recording --workflow workflow.yml` | `recording.jsonl` + `dom/*.html` |
| 3. Compile | `freentonic --compile-recording recording.jsonl --out draft.yml` | a draft `connect:` pipeline |
| 4. Review | *(your editor)* | selectors/secrets fixed |
| 5. Lint | `freentonic --lint --workflow draft.yml` | pass/fail |
| 6. Step | `freentonic --step --workflow draft.yml` | live selector validation |
| 7. Capture | `freentonic --workflow draft.yml --through extract --dump-raw raw.json` | the raw payload to shape |

## Step 1 — Bootstrap the stub

`--recording` and `--step` both need a `--workflow` with an initial URL to
launch at, so a brand-new provider needs one minimal file. `--init` writes it,
prompting for three things:

- the **initial login URL** (required);
- the **secret names** the login needs (space-separated, e.g. `USER_ID
  USER_PIN` — names only, never values: secrets arrive at runtime via
  `--secrets`, they are never stored in the workflow);
- an optional **post-login ("ready") URL** that confirms success.

```sh
freentonic --init                       # interactive: prompts for the three above
# or non-interactively:
freentonic --init --url https://bank.example/login \
  --secret USER_ID --secret USER_PIN \
  --ready-url https://bank.example/home
```

It writes `workflow.yml` (override with `--out PATH`) — `version: 1`, a
`config.key: REPLACE_ME`, a `secrets:` block for the names you gave, a
`connect:` phase with the initial `navigate`, and (if you gave a ready URL) a
commented `wait_url` scaffold to drop in after your login steps. Invalid secret
tokens are skipped with a note, and it refuses to overwrite an existing file.
The stub lints clean, so the record loop starts on solid ground.

> Compiling a recording writes a **fresh** draft (it doesn't read the stub),
> so if you take the record → compile path, compile to a separate `--out` file
> and copy your `secrets:` block and `wait_url` across. The richer stub is most
> useful when hand-authoring or as your secret/success-URL reference.

## Step 2 — Record the login by hand

```sh
freentonic --recording --reset-profile --workflow workflow.yml
```

Chrome opens at the initial URL. **Drive the login yourself** (in noVNC under
the author container) — type your identifier, password/PIN, solve 2FA, click
through to the logged-in state. Then **Ctrl-C** to end.

- Every click / fill / submit / navigation is captured to `recording.jsonl`.
  Credential fields are **masked in-page**, so the recording never holds the
  raw values.
- **`--reset-profile`** wipes the persistent profile first, forcing the bank's
  full-entry login. Without it, a profile that "remembers" you skips the
  identifier step and you can't record it. (`--isolated` is the ephemeral
  equivalent — a throwaway profile that never persists.)
- Interactions inside **open shadow DOM** (sites that render login as web
  components) are captured with shadow-piercing selectors — the recorder
  handles them automatically.
- **`dom/<session>/NNNN.html`** — a per-step DOM+shadow snapshot lands next to the
  recording (on by default in the author container; `FREENTONIC_RECORD_DOM=0`
  to skip). Each file is the page **as that step acted on it**, open shadow
  roots serialized as declarative `<template shadowrootmode="open">`, input
  values stripped. This is your offline source of truth for selectors (see
  Step 4). A `dom_ref` on each JSONL line points at the snapshot.

## Step 3 — Compile the recording into a draft

```sh
freentonic --compile-recording recording.jsonl --out draft.yml
```

Deterministic, no Chrome. It emits a full draft — `version`, `config`, a
`secrets:` block for each masked field, `pipeline`, and a `connect:` phase
where each recorded interaction became a `wait_for_selector:` + `click:` /
`fill:`. Masked fields compile to `value: secret(NAME)` by construction. It is
a **draft, not a finished provider**. (`--out` refuses to write inside a git
work tree, since a draft can carry a captured username literal — write it to
the workspace or `/tmp`, review, then copy into your provider repo.)

## Step 4 — Review the draft

Open the draft and resolve every flag the compiler left:

- **`config.key: REPLACE_ME`** → your provider key.
- **`secrets:`** entries with `REPLACE_ME` prompts → real descriptions.
- **`# REVIEW: literal from recording`** → an unmasked value kept verbatim
  (could be a username/PII). Turn it into `secret(...)` if sensitive.
- **`# REVIEW: nth-child selector, may be fragile`** → replace the positional
  path with a stable hook.
- **`# REVIEW: auto-generated id — regenerates each load`** → the element's
  `id` looked machine-generated, so the recorder fell back to it. Swap in the
  stable attribute (`name` / `placeholder` / `aria-label`) — see below.
- **`# REVIEW: no selector captured`** → the recorder couldn't derive one;
  find a selector by hand.
- **`# NOTE: element is inside shadow DOM`** → informational. The selector is
  scoped to a shadow root, so it won't match in a browser console's plain
  `querySelector`, but freentonic's actions pierce shadow roots and replay it
  fine. Nothing to change.

### Finding a stable selector from the DOM snapshots

When the compiler's pick is a fragile positional path or a machine-generated
id, the `dom/*.html` snapshots have the answer. Grep a snapshot for the
element and read its durable attributes:

```sh
grep -o '<input[^>]*>' dom/0003.html | grep -i userid
```

Prefer, in order: a stable `id` → `data-testid` → `name` → `placeholder` →
`aria-label`. A web-component login often hides these behind a per-render id;
the snapshot is where you recover them.

## Step 5 — Lint

```sh
freentonic --lint --workflow draft.yml
```

Static validation of schema, selectors, and secret references — no Chrome.
Exit `0` = clean, `1` = errors printed. Loop back to Step 4 until it's clean.

## Step 6 — Step through live

This is the **observe → act → observe** loop — the core selector-validation
tool. It holds one Chrome session open so a wrong selector costs one line, not
a full re-login:

```sh
freentonic --step --workflow draft.yml --secrets cli
```

It prints a ready envelope, then reads **one action per line from stdin** and
prints a **result envelope per line to stdout** (logs go to stderr). Lines are
JSON, or a single-line YAML flow mapping if you're typing by hand. Two control
words: `page` emits a fresh page observation, `quit`/`exit` closes.

```
{"ok":true,"ready":true,"url":"https://bank.example/login"}   ← printed by --step
page                                                          ← you: what's on the page?
{"ok":true,"page":{"interactive":[{"tag":"input","selector":"#userid","label":"User ID","masked":false}, …]}}
{"action":"fill","selector":"#userid","value":"secret(USER_ID)"}
{"ok":true,"action":"fill"}
{"action":"click","selector":"#wrong"}
{"ok":false,"action":"click","error":"click: selector not found: #wrong","observation":{"interactive":[…]}}
{"action":"click","selector":"#submit"}
{"ok":true,"action":"click"}
quit
```

- **`page`** (or an `inspect_page` action) returns the structured element
  inventory with a suggested selector for each element — the same heuristic
  the recorder uses. Values are never surfaced, only whether a field is
  `masked`. This is how you find a selector without diffing screenshots.
- A **failed action doesn't tear the session down** — it returns the error
  plus a fresh observation, so you immediately see what *is* on the page.
- Watch **`failures.ndjson`** in the workspace: when a `wait_for_selector` /
  `wait_*` times out, freentonic appends a machine-readable record (what it
  waited for, the timeout, a page observation) — the "why did the wait fail"
  log.
- Every selector you confirm here goes straight back into the draft.

## Step 7 — Capture credentials and shape the data

Once `connect:` is solid, run the full connect + capture, then dump the raw
API payload to build the `extract:` / `normalize:` plans:

```sh
freentonic --workflow draft.yml --through extract --dump-raw raw.json --secrets cli
```

`raw.json` is the real API response the workflow captured — the input you
write the extract/normalize plans against. That half is covered by
[extract-plan.md](extract-plan.md) and [normalize-plan.md](normalize-plan.md).
Write both as plans: `author` runs declarative-only, like a production
server, so a `ruby:` extractor or normalizer is refused here too
(`FREENTONIC_ALLOW_PROVIDER_RUBY` isn't passed in).

If the bank's API can't be called from outside the page (its requests are
encrypted or signed in the browser), there's no `api_client:` to dump:
capture the app's own responses instead and hand them to the plan through a
`captured:` block. The pitfalls — page hydration, clicking rather than
navigating, "Load more" history — are in
[capturing data from a web app's own responses](workflow-action-capture-response-json.md#capturing-data-from-a-web-apps-own-responses).

---

## Selectors: what the recorder can and can't do for you

The recorder derives selectors automatically and prefers stable hooks
(`id` → `data-testid` → `name` → `placeholder` → `aria-label`) over positional
paths. It also **demotes machine-generated ids** (per-render random tokens)
below the stable attributes and flags them, so a precise-looking-but-volatile
selector isn't shipped as safe. Shadow DOM is pierced automatically at both
record and replay.

## Known limitations — expect to hand-edit these

The recorder captures the common cases; a few patterns are inherently manual:

- **Form-associated custom elements.** Some components keep a field's value
  only in internal (`ElementInternals` / JS) state, not on any inner
  `<input>.value`. That value isn't observable from outside, so the field
  records a **click but no fill**. Fix: add one line —
  `fill: <stable-selector> value: secret(NAME)` — using the selector the DOM
  snapshot / `inspect_page` gives you.
- **Position-scrambled or grid inputs** (e.g. a keypad whose key positions
  shuffle each load). The recorder captures your literal key clicks, which
  won't replay — and they can encode the secret. Delete those steps and use
  the dedicated action for that pattern (see the action docs).
- **Redundant navigations/clicks.** A recording may carry duplicate
  `wait_url:` expectations or a stray click. Prune them.

## A note on sensitive artifacts

`recording.jsonl`, the `dom/*.html` snapshots, and `--dump-raw` output all
capture live session data (structure, page text, API payloads — values are
masked/stripped where noted, but page text is not). In the author container
they're written owner-only (`umask 0077`) and the workspace is refused inside
a git work tree. Keep them out of any repo; author in a scratch dir and copy
only the finished `workflow.yml` into your provider repo.
