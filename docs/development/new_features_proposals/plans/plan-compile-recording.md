# Implementation plan — `--compile-recording` (recording.jsonl → workflow.yml draft)

Plan for [`proposal-recording-to-workflow-compiler.md`](../proposal-recording-to-workflow-compiler.md).
Ground-truth verified against the working tree.

## Goal

`freentonic --compile-recording PATH [--workflow existing.yml] [--out PATH]`:
a deterministic, no-Chrome, no-network data transform that reads a
`recording.jsonl` (the file `--recording` mode already writes) and emits a
draft `connect:` pipeline as YAML — masking credentials into
`secret(...)` by construction and producing `--lint`-clean output. The
output is explicitly a **draft, never a finished provider**.

## Sequencing

Ship **after** `--schema-json` (shares the "authoring-loop" framing and
benefits from the machine-readable dialect), but it has **no hard code
dependency** — it can land independently. It is the highest
value-per-diff item: it turns an artifact freentonic already produces into
a runnable starting point.

## Ground truth (verified anchors)

### The input: `recording.jsonl`

- Writer: `Recorder#append` (`recorder.rb:151-155`) — one `JSON.generate`
  object per line, file mode `0600`. Format comment at `recorder.rb:22-24`.
- **Event `kind` values that actually appear:**
  - probe-emitted (`recorder/probe.js`): **`click` (211), `fill` (222, on
    `change`), `submit` (236), `probe_ready` (241)** — that's all four.
  - Ruby-synthetic (`recorder.rb`): `recorder_started` (64), `navigate`
    (133-137, top-level frames only, skips `about:blank`),
    `recorder_error` (94-98), `recorder_stopped` (113).
  - **Correction vs. proposal:** the probe header comment mentions a
    `kind: "skipped"` for closed shadow roots, but **no such event is ever
    emitted** — do not write a mapping rule for it. The proposal's
    "drop `probe_ready`/`recorder_*`" is right; just drop everything whose
    `kind` is not in `{navigate, click, submit, fill}`.
- Every event has `t` (epoch ms).
- Interaction-event keys (from `elementSummary`, `probe.js:175-191`):
  `tag`, `selector`, `selector_strategy`, `needs_review`, optional `text`/
  `role`/`href`, plus per-listener `kind`, `url`. `fill` additionally
  carries **either** `mask: true` **or** `value: <string>`, never both
  (`probe.js:216-231`), plus `input_type`.
- `needs_review == true` ⟺ selector strategy is `nth-child` or `none`
  (`selectorFor`, `probe.js:56-113`) — the `# REVIEW:` trigger.
- Masked values never reach the file: `describeInputValue`
  (`probe.js:157-173`) blanks the value in-page for password/otp/2fa/
  cvv/pin-ish fields. So the compiler can never see a secret value.

### The output: the action dialect

`SPECS` (`workflow_actions.rb:29-63`) — the five actions the compiler emits:

```ruby
"navigate"          => { required: %w[url] },
"wait_url"          => { required: %w[includes], optional: %w[timeout] },
"wait_for_selector" => { required: %w[selector], optional: %w[timeout] },
"click"             => { required: %w[selector] },
"fill"              => { required: %w[selector value], optional: %w[clear] },
```

- `secret(NAME)` syntax: `SecretResolver::SECRET_PATTERN =
  /\Asecret\(([^)]+)\)\z/` (`secret_resolver.rb:19`) — **anchored**, so the
  whole value must be `secret(password)` (no interpolation inside a larger
  string). Declared under a top-level `secrets:` block read by
  `WorkflowSchema#secrets` (`workflow_schema.rb:49-51`), each entry
  `NAME: { prompt: "..." }`.
- Minimal valid workflow top-level keys: `version` (must == 1),
  `config`, `secrets`, `pipeline` (list of phase names, each must exist in
  `phases`), `phases` (Hash of name → Array|null). `extract`/`normalize`/
  `credentials`/`api_client` are all optional — **a connect-only workflow
  validates fine** (`validate!`, `workflow_schema.rb:279-318`). There is
  **no reserved `connect` phase name**; the Scaffold conventionally names
  the first phase `connect` but any name works.

### Lint-clean guarantee

- `Linter.new(workflow_path:, stdout:, stderr:).run` returns an **Integer
  exit code** (`0` clean / `1` errors), *not* an array (`linter.rb:26,36-57`).
- For a connect-only draft, extract/normalize/api_client/credentials
  checks early-return; only `check_secrets` (`linter.rb:159-166`) runs and
  merely **warns** on undeclared secrets. So output is 0-errors (and
  warning-clean) iff: (a) every step uses a `SPECS` action with its
  `required` keys, and (b) every `secret(NAME)` emitted has a matching
  `secrets:` entry.

### Rendering style

- `Freentonic::Providers::Scaffold` (`lib/freentonic/providers/scaffold.rb`)
  renders via **hand-rolled heredoc string templating, not Psych** — that
  is the only way inline `# REVIEW:` comments survive (Psych can't emit
  them). Reuse the *style*, not `generate!` (which writes files to disk).
  Placeholders like `REPLACE_WITH_*` express the "draft" contract.

### CLI + guards

- `--lint` model to copy: `opts.on` at `cli.rb:131`; short-circuit
  `return run_lint(options) if options[:lint]` at `cli.rb:31`; handler
  `run_lint` at `cli.rb:235-242` (no Engine, no Chrome). `--recording`
  already exists (`cli.rb:137`).
- **No `--out` flag exists today** — it is new.
- Git-repo write-refusal to mirror: `debug_request_writer.rb#validate_path!`
  (37-54) + `detect_git_root` (56-66). Note it detects a `.git`
  **directory** only (walks up from `Dir.pwd`); it does not catch linked
  worktrees (whose `.git` is a file).

## Mapping rules (deterministic)

| Recording event | Emitted | Notes |
| --- | --- | --- |
| first `navigate` | `action: navigate, url:` | workflow entry URL |
| subsequent `navigate` | `action: wait_url, includes: <path>` | model redirect as expectation; use URL path/tail, not full URL |
| `click` / `submit` | `action: wait_for_selector` (on target) **then** `action: click` | robust-by-construction |
| `fill` + `mask: true` | `action: fill, selector, value: secret(NAME)` + a `secrets:` entry | credential correct by default |
| `fill` (unmasked) | `action: fill, selector, value: "<literal>"` + `# REVIEW: literal from recording` | author must see/decide |
| any event `needs_review: true` | the emitted step + `# REVIEW: nth-child selector, may be fragile` | |
| empty selector (`strategy: none`) | emit step + `# REVIEW: no selector captured` | never invent a selector |
| `probe_ready` / `recorder_*` / any other kind | — | dropped |

- Coalesce consecutive duplicate `navigate`s and no-op events.
- Secret naming: derive a stable `NAME` per masked field (e.g. from
  `input_type`/selector — `password`, `otp`, `pin`; de-dupe with a counter
  if two masked fields collide). Emit one `secrets: { NAME: { prompt:
  "REPLACE_ME: describe the secret" } }` entry per distinct name.

## Implementation steps

1. **New `Freentonic::RecordingCompiler`**
   (`lib/freentonic/recording_compiler.rb`):
   - `initialize(recording_path:, workflow_path: nil, stdout:, stderr:)`.
   - Read the JSONL line-by-line, `JSON.parse` each (skip blank/malformed
     lines with a stderr warning — the recorder flushes per line so a
     truncated last line is possible).
   - Build an ordered list of emitted steps + a set of declared secrets by
     applying the mapping table. Keep a small internal step struct that
     carries optional leading `# REVIEW:` comment lines so the renderer can
     place them.
   - Render YAML via heredoc templating (Scaffold style). Emit
     `version: 1`, a `config: { key: REPLACE_ME }` stub, the `secrets:`
     block (only if any masked fill), `pipeline: [login]` (or the grafted
     phase name), and `phases: { login: [ ...steps... ] }`.
   - Return the YAML string; the CLI decides stdout vs `--out`.

2. **`--workflow` graft mode:** when given, load the existing workflow
   (`WorkflowSchema.load` for validation, but re-read raw for editing),
   replace/insert the compiled steps into the named connect phase, and
   re-emit. *Decision:* graft is strictly more complex (must preserve the
   rest of the file, including comments Psych would drop). Recommend
   **shipping stdout/`--out` fresh-draft mode first** and treating graft as
   a fast-follow — the proposal lists it but the fresh draft delivers most
   of the value. Confirm scope with the user.

3. **Emit only registry-valid actions.** The compiler only ever produces
   the five action names above with their `required` keys present — a test
   locks this against `WorkflowActions` (drift guard).

4. **Wire the flags** in `cli.rb` (mirror `--lint`, no Engine/Chrome):
   ```ruby
   opts.on("--compile-recording PATH", "Compile a recording.jsonl into a draft connect: pipeline (YAML to stdout)") { |v| options[:compile_recording] = v }
   opts.on("--out PATH", "Write --compile-recording output to PATH instead of stdout") { |v| options[:out] = v }
   ```
   Short-circuit in `#run` (before `validate!`, like a self-contained
   flag), via `run_compile_recording(options)`. When `--out` is inside a
   git repo, **refuse** with a `debug_request_writer`-style error (the
   output can contain a username literal). *Improvement over that guard:*
   use `git rev-parse --is-inside-work-tree` (array-form `Process`/`Open3`,
   invariant 3) so linked worktrees are also caught — the existing
   `detect_git_root` misses them.

5. **Stderr warning on unmasked-fill literals.** When any unmasked `fill`
   literal is written, emit one `[compile-recording] wrote N literal
   value(s) from the recording — review before committing` line to stderr
   (mirrors the `dump_requests` refusal ethos; these can be usernames/PII).

## Tests (`test/recording_compiler_test.rb`)

- `test_compile_maps_each_event_kind` — table test over
  navigate/click/submit/fill(masked)/fill(unmasked) → asserts emitted
  action + keys.
- `test_masked_fill_becomes_secret_and_declares_it` — `value: secret(...)`
  **and** a matching `secrets:` entry.
- `test_output_is_lint_clean` — compile a fixture, write to a tempfile,
  run `Linter.new(...).run`, assert exit `0` (strongest guarantee).
- `test_needs_review_selectors_are_flagged` — `# REVIEW:` on `nth-child`
  events; `# REVIEW: no selector captured` on empty selector.
- `test_bookkeeping_events_dropped` — `probe_ready`/`recorder_*` → no steps.
- `test_subsequent_navigate_becomes_wait_url` — first `navigate` →
  `navigate`, later `navigate` → `wait_url` with the path.
- `test_out_path_inside_git_repo_is_refused` — mirror
  `debug_request_writer`'s git-path test.
- `test_only_registry_actions_emitted` — every emitted `action:` is in
  `WorkflowActions.names` (drift guard).
- (if graft ships) `test_graft_mode_replaces_named_phase`.

Fixture: hand-craft a small `recording.jsonl` (the proposal's example is a
good seed) under `test/fixtures/` — **scrubbed, no real data** (AGENTS.md
safety rail).

## Docs

- README: add `--compile-recording` / `--out` to the CLI flag list, with
  the "draft, not a finished provider — read, edit, `--lint`" contract.
- Cross-link from the recording docs and (later) the `author` container doc.

## Risks / decisions

- **Graft mode scope** — recommend deferring; confirm with user.
- **Secret-name derivation** — needs a deterministic, collision-safe rule;
  document it so re-compiling the same recording is stable.
- **Malformed/truncated last line** — tolerate (warn + skip), don't crash.
- Output may contain a username literal → the git-refusal guard + stderr
  warning are load-bearing, not optional.

## Completion checklist (AGENTS.md)

- [ ] `bundle exec rake test` green (incl. `test_output_is_lint_clean`).
- [ ] `../freentonic-providers` `rake test` green.
- [ ] No runtime gem added; no Chrome/network in the code path.
- [ ] README updated.
- [ ] Branch handed back.

**Estimated effort:** ~1 day for fresh-draft mode + tests; +0.5–1 day if
graft mode is in scope.
