# Proposal — Incremental step execution + on-demand page observation

**Status:** draft. The architectural centerpiece of the LLM authoring
loop
([`docs/llm-workflow-authoring-review.md`](../../llm-workflow-authoring-review.md)
P1 #5 + #6). Larger than the two P0 compilers; ship those first. Builds
on the existing `pause` / recording / remote-prompt plumbing.

**Motivation:** today the unit of execution is a whole workflow run. An
LLM (or a human) drafting a login flow finds out a selector on step 7
was wrong only after a full re-login — which burns 2FA patience and
anti-bot budget, and takes minutes per iteration. There is no way to
hold a browser session open and try **one action at a time**, observing
the result before deciding the next step. That closed
`observe → act → observe` loop is the single biggest missing primitive
for autonomous authoring. Two capabilities compose to provide it:

1. **`inspect_page`** — structured, on-demand page observation (text, not
   pixels): URL, title, and an inventory of visible interactive elements
   *with YAML-ready selector candidates*.
2. **Step execution** — a held-open Chrome session that runs a single
   action and returns its outcome, looped.

## Why this belongs in the framework

- The selector heuristics an authoring agent needs already exist in
  [`recorder/probe.js`](../../../lib/freentonic/recorder/probe.js)`#selectorFor`
  but only fire on human interaction events. Exposing them on demand is a
  framework capability by definition — it reuses the framework's CDP
  session and its own selector logic.
- `BrowserWorkflowRunner#execute_step`
  ([`browser_workflow_runner.rb:71`](../../../lib/freentonic/browser_workflow_runner.rb))
  is already per-action and stateless between steps against a persistent
  `@session`. The engine change is small; the work is the
  session-lifecycle wrapper (holding Chrome open past one phase) and a
  thin protocol.
- Keeping it in-framework means the same session, stealth flags,
  recording, and remote-prompt machinery an eventual production run uses
  are what the agent iterates against — no divergent debug harness.

## Scope — two tiers, each independently shippable

### Tier 1: `inspect_page` action + observation primitive

A new workflow action and an underlying `PageObserver` that an agent can
also call directly (Tier 2 / the server). Returns structured text.

```yaml
- action: inspect_page
  as: page          # optional; also printed to the run log
```

Output shape (into `@context[as]`, and serialized for the server path):

```json
{
  "url": "https://bank.example/login",
  "title": "Acme Bank — Sign in",
  "interactive": [
    { "tag": "input",  "selector": "#user", "selector_strategy": "id",
      "needs_review": false, "type": "text", "label": "Usuario" },
    { "tag": "input",  "selector": "#pass", "selector_strategy": "id",
      "needs_review": false, "type": "password", "masked": true },
    { "tag": "button", "selector": "button[name='submit']",
      "selector_strategy": "name", "needs_review": false, "text": "Entrar" }
  ]
}
```

#### Implementation

- **Move the selector heuristics into a reusable probe.** `selectorFor`,
  `nthChildPath`, `cssEscape`, `describeInputValue`, and `visibleText`
  currently live inside the event-listener IIFE in
  `recorder/probe.js`. Extract them into a shared source string both the
  recorder and a new `observe.js` can inject — `observe.js` walks the
  visible interactive elements (`a`, `button`, `input`, `select`,
  `[role=button]`), runs the same `elementSummary`, and returns the
  array. Injected via `Runtime.evaluate` and read back synchronously — no
  binding channel needed (unlike the recorder, this is request/response).
- **`Freentonic::PageObserver.observe(session)`** runs the eval, parses
  the JSON, returns the hash. Reuses the shadow/iframe-piercing
  `deepQuery` already in the runner
  (`browser_workflow_runner.rb#DEEP_QUERY_FN`) so it sees inside custom
  components.
- **Dispatch** `inspect_page` in `execute_step`, register it in
  `WorkflowActions::SPECS` (`required: []`, `optional: %w[as]`). Like
  every capture action, it **never logs element values** — only
  tag/selector/strategy/label — so a pre-filled field can't leak into the
  run log.
- **Machine-actionable failures (review P0 #4) fall out of this:** call
  `PageObserver.observe` at each `save_timeout_screenshot` site and write
  the inventory to `<run_dir>/failures.ndjson` next to the screenshot.
  Now a `wait_for_selector` timeout tells an agent *what was actually on
  the page* and which near-miss selectors existed.

### Tier 2: held-open step session

Run one action against a live session, return the outcome, loop. Two
front-ends over one engine.

#### CLI REPL

```sh
freentonic --step --workflow draft.yml
```

Launches Chrome + CDP exactly as Connect does, navigates to the
workflow's initial URL, then reads one action per request from stdin
(a YAML fragment or a bare `action: ...` line), runs it, and prints a
result envelope to stdout:

```
> { "action": "fill", "selector": "#user", "value": "012345" }
{ "ok": true, "action": "fill", "elapsed_ms": 640 }
> { "action": "inspect_page" }
{ "ok": true, "url": "...", "interactive": [ ... ] }
> { "action": "click", "selector": "#nope" }
{ "ok": false, "action": "click", "error": "selector not found: #nope",
  "observation": { "interactive": [ ... ] } }
```

On failure it attaches a Tier-1 observation so the next guess is
informed. `EOF`/`quit` closes the session cleanly.

#### Server sessions

For the autonomous/headless path, mirror the shape onto the invoke
server:

- `POST /sessions` `{workflow, ...}` → `201 {session_id}` — opens and
  holds a Chrome+CDP session; enforces the same one-at-a-time serialization
  and per-session idle timeout the invoke worker already uses.
- `POST /sessions/:id/step` `{action, ...}` → the result envelope above.
- `GET  /sessions/:id/page` → a Tier-1 observation on demand.
- `DELETE /sessions/:id` → close Chrome, clean the profile.

This reuses the existing remote-prompt store (OTP/SCA still work
mid-session) and the recorder (a session can be opened with
`recording: true` so every step is also captured).

#### Implementation

- **Expose a public per-step entry** on the runner. `execute_step` is
  private ([`browser_workflow_runner.rb:71`](../../../lib/freentonic/browser_workflow_runner.rb));
  add a public `run_action(step_hash)` that wraps it, catches
  `UserError`/`ChromeCdp::Error`/`KeyError`, and returns the
  `{ok:, error:, observation:}` envelope instead of raising. One runner
  instance is constructed against the held-open `@session` and reused
  across steps (it is already stateless between steps — see
  `run_pipeline` in `stages/connect.rb:207`, which builds one runner per
  *phase* against the same session).
- **A `Stages::Connect` "step" mode** (sibling to the existing
  `interactive`/`recording` branches at `stages/connect.rb:21-44`) that
  runs `launch_chrome → open_login_session → mask_webdriver →
  navigate_to_initial_url`, then hands control to a `StepDriver` idle
  loop instead of `run_pipeline`. The teardown `ensure` block
  (`stages/connect.rb:64-75`) already closes the session, recorder, and
  isolated profile — the step session inherits all of it.
- **Serialization + timeouts on the server** reuse the invoke worker's
  `@invoke_mutex` model and watchdog; a held session counts against the
  same one-run-at-a-time guarantee and gets an idle-timeout so an
  abandoned session can't pin Chrome forever.

## Security considerations

- **A step session is arbitrary workflow-action execution against a live
  bank session** — that is the same trust level as running a workflow
  (SECURITY.md: "YAML is code"), just interactive. The server surface
  therefore sits behind the same bearer-token auth as `/invoke`, and
  `POST /sessions/:id/step` accepts only registered action names with
  their required keys (validated through `WorkflowActions`), never
  arbitrary Ruby.
- **`inspect_page` returns element *metadata*, never values** — the same
  no-leak discipline every `capture_*` action follows. Password/otp/pin
  fields are reported `masked: true` with no value, reusing the probe's
  `describeInputValue` sensitivity check.
- **Held sessions are the one new resource-exhaustion vector.** Bound
  them: one open session at a time (same as invoke serialization), a
  hard idle timeout, and `DELETE` on shutdown drain. No unbounded session
  pool.
- **`failures.ndjson`** carries page structure (selectors, labels) but no
  field values; written 0600 into the run dir like every other artifact.

## Tests

- `test_inspect_page_returns_interactive_inventory` — against
  `FakeSession` seeded with a canned `Runtime.evaluate` result, assert
  the parsed inventory and that no element *values* appear.
- `test_inspect_page_marks_sensitive_inputs_masked` — password field →
  `masked: true`, no value.
- `test_run_action_ok_envelope` / `test_run_action_error_envelope` —
  `run_action` returns `{ok:true}` on success and `{ok:false, error:,
  observation:}` on a missing selector, never raises.
- `test_step_session_reuses_one_runner_across_actions` — two actions on
  one session share `@context` (a `capture_url` then a `when_context`
  gate reading it).
- `test_timeout_writes_failure_observation` — a `wait_for_selector`
  timeout writes a `failures.ndjson` line with the inventory.
- Server: `test_sessions_lifecycle` (open → step → page → delete),
  `test_step_requires_auth`, `test_step_rejects_unknown_action`,
  `test_second_open_session_is_serialized_or_rejected`,
  `test_idle_session_times_out_and_frees_chrome`.
