# Proposal — `--compile-recording`: recording.jsonl → workflow.yml draft

**Status:** draft. Depends on nothing to ship, but is most useful
alongside `--schema-json`
([`proposal-schema-json-export.md`](proposal-schema-json-export.md)) and
`--step`
([`proposal-incremental-step-session.md`](proposal-incremental-step-session.md)).
P0 #2 of
[`docs/llm-workflow-authoring-review.md`](../../llm-workflow-authoring-review.md).

**Motivation:** `--recording` mode already walks a bank's UI and emits a
selector-annotated event stream to `<run_dir>/recording.jsonl`
([`recorder.rb`](../../../lib/freentonic/recorder.rb),
[`recorder/probe.js`](../../../lib/freentonic/recorder/probe.js)). Each
event carries a derived CSS selector, a `selector_strategy`
(`id → data-testid → name → aria-label → nth-child`), a `needs_review`
flag, and — for inputs — a `mask` flag when the field looks sensitive.
That is *exactly* the information a `connect:` pipeline needs, and the
recorder was built for it: its header comment says the masking flag is
there "so the recorder can substitute `secret(...)` if it knows the
name" ([`recorder.rb:20`](../../../lib/freentonic/recorder.rb)). But
nothing consumes the file — the translation from events to YAML is
entirely manual/LLM freehand today. This proposal adds the deterministic
compiler that closes that gap.

**Consuming use case:** every new provider. The recorder produces the
raw material; an author (human or LLM) currently retypes it into YAML by
hand, mis-transcribing selectors and forgetting to mask credentials.
A one-shot compile gives a runnable, `--lint`-clean starting point.

## Why this belongs in the framework

- The event format is framework-defined (`recorder/probe.js`), and the
  target dialect is framework-defined (`WorkflowActions`). Only the
  framework can map one to the other authoritatively; a provider-side
  script would drift from both.
- It is pure data transformation — no Chrome, no network, no new trust
  boundary. It reads a file freentonic wrote and writes YAML.
- It makes the recorder's existing selector heuristics *pay off*. Today
  they're computed and thrown into a JSONL nobody reads programmatically.

## Scope

One new flag. Reads a `recording.jsonl`, writes a draft workflow (or a
`connect:` pipeline fragment) to stdout or `--out`.

```sh
freentonic --compile-recording run/recording.jsonl > draft.yml
# or graft onto an existing workflow's connect phase:
freentonic --compile-recording run/recording.jsonl --workflow providers/acme/workflow.yml
```

The output is explicitly a **draft, never a finished provider** — same
contract the `Scaffold` template already sets. It is meant to be read,
edited, and `--lint`ed, not shipped blind.

### Mapping rules (deterministic)

| Recording event | Emitted action | Notes |
| --- | --- | --- |
| first `navigate` | `navigate: {url}` | the workflow's entry URL |
| subsequent `navigate` | `wait_url: {includes: <path>}` | model the redirect as an expectation, not a drive |
| `click` / `submit` | `wait_for_selector` on the target, then `click` | robust-by-construction: wait before click |
| `fill` with `mask: true` | `fill: {selector, value: "secret(REPLACE_ME)"}` + a generated `secrets:` entry | credential handled correctly by default |
| `fill` (unmasked) | `fill: {selector, value: "<literal>"}` | flagged with a `# REVIEW: literal from recording` comment |
| any event with `needs_review: true` | the emitted step | prefixed with `# REVIEW: nth-child selector, may be fragile` |
| `probe_ready` / `recorder_*` | — | dropped (bookkeeping, not user actions) |

Consecutive duplicate navigations and no-op events are coalesced. The
compiler never invents a selector — if an event's selector is empty it
emits the step with a `# REVIEW: no selector captured` marker so the gap
is visible rather than silently dropped.

### Example

Input (`recording.jsonl`, abridged):

```json
{"kind":"navigate","url":"https://bank.example/login","t":1}
{"kind":"fill","selector":"#user","selector_strategy":"id","needs_review":false,"value":"012345","t":2}
{"kind":"fill","selector":"#pass","selector_strategy":"id","needs_review":false,"mask":true,"t":3}
{"kind":"click","selector":"button[name='submit']","selector_strategy":"name","needs_review":false,"t":4}
{"kind":"navigate","url":"https://bank.example/dashboard","t":5}
```

Output (`draft.yml`, abridged):

```yaml
version: 1

secrets:
  password:
    prompt: "REPLACE_ME: describe the secret"

config:
  key: REPLACE_ME

pipeline:
  - login

phases:
  login:
    - action: navigate
      url: https://bank.example/login

    - action: fill
      selector: "#user"
      value: "012345"   # REVIEW: literal from recording

    - action: fill
      selector: "#pass"
      value: secret(password)

    - action: wait_for_selector
      selector: "button[name='submit']"
    - action: click
      selector: "button[name='submit']"

    - action: wait_url
      includes: "/dashboard"
```

## Implementation

- **New `Freentonic::RecordingCompiler`** (`lib/freentonic/recording_compiler.rb`):
  reads the JSONL line-by-line (same format `Recorder#append` writes),
  applies the mapping table above, and renders YAML via stdlib `YAML`
  (or a small hand-rolled emitter to control comment placement — the
  `# REVIEW:` markers matter and `Psych` won't emit them, so a light
  templated renderer like `Scaffold` uses is the pragmatic choice).
- **Emit actions the registry validates.** The compiler only ever
  produces action names in `WorkflowActions.names` with their required
  keys present, so the output is `--lint`-clean by construction. A test
  asserts this against the registry (drift guard).
- **`--workflow` graft mode:** when given, parse the existing workflow,
  replace/insert the compiled steps into the named connect phase, and
  re-emit — so re-recording a broken login updates the draft instead of
  starting over.
- **Wire the flag** in `Cli#parse` and short-circuit in `Cli#run`
  (no Chrome, like `--lint`/`--schema-json`):

  ```ruby
  opts.on("--compile-recording PATH", "Compile a recording.jsonl into a draft connect: pipeline (writes YAML to stdout)") { |v| options[:compile_recording] = v }
  opts.on("--out PATH", "Write --compile-recording output to PATH instead of stdout") { |v| options[:out] = v }
  ```

## Security considerations

- **Unmasked fills can carry PII/usernames.** The compiler emits them as
  literals with a `# REVIEW:` marker — never silently. That is the right
  default for authoring (the author must see and decide), but the output
  file therefore may contain a username and must not be committed blind.
  Emit a one-line stderr warning when any unmasked `fill` literal is
  written, mirroring the `dump_requests` git-repo-path refusal ethos.
- **Masked fills never leak a value** — the probe strips the value
  in-page (`describeInputValue`), so `recording.jsonl` never contained
  it; the compiler emits `secret(REPLACE_ME)`. No new exposure.
- No Chrome, no network, no execution of recorded content — it is parsed
  as data, never `eval`'d.

## Tests

- `test_compile_maps_each_event_kind` — table test over
  navigate/click/submit/fill(masked)/fill(unmasked), asserting the
  emitted action + keys.
- `test_masked_fill_becomes_secret_and_declares_it` — assert
  `value: secret(...)` and a matching `secrets:` entry.
- `test_output_is_lint_clean` — compile a fixture, run it through the
  `Linter`, assert zero errors (the strongest guarantee — output is
  always runnable-shaped).
- `test_needs_review_selectors_are_flagged` — assert `# REVIEW:` markers
  on `nth-child` events.
- `test_graft_mode_replaces_named_phase` — `--workflow` given, assert the
  compiled steps land in the right phase and the rest is untouched.
- `test_bookkeeping_events_dropped` — `probe_ready`/`recorder_*` produce
  no steps.
