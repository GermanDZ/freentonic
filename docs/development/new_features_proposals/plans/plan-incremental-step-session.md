# Implementation plan — `inspect_page` + held-open step session

Plan for [`proposal-incremental-step-session.md`](../proposal-incremental-step-session.md).
Ground-truth verified against the working tree. This is the largest of
the four features; it splits into two independently-shippable tiers.

## Goal

Close the `observe → act → observe` loop for authoring:

1. **Tier 1 — `inspect_page` action + `PageObserver`.** On-demand
   structured page observation (text, not pixels): URL, title, and an
   inventory of visible interactive elements each with a YAML-ready
   selector candidate, strategy, and `needs_review` flag. Also backs
   machine-actionable failure output (`failures.ndjson`).
2. **Tier 2 — held-open step session.** One Chrome+CDP session that runs a
   single action, returns its outcome (with a Tier-1 observation attached
   on failure), and loops. Two front-ends over one engine: a CLI REPL
   (`--step`) and server endpoints (`POST /sessions`, `/sessions/:id/step`,
   `GET /sessions/:id/page`, `DELETE /sessions/:id`).

## Sequencing

Ship **after** `--schema-json` and ideally **after** `--compile-recording`
(the review's P1, those are P0). Within this feature: **Tier 1 first** — it
is small, high-value on its own (`failures.ndjson` alone is worth it), and
Tier 2 depends on it (failed steps attach a Tier-1 observation).

## Ground truth (verified anchors)

### Runner internals — `lib/freentonic/browser_workflow_runner.rb`

- `execute_step(step)` is at **line 71** and is **private** (`private` at
  65). Only public methods: `initialize` (38) and `execute_phase` (53).
  Dispatch is a `case action` at **84-272**, `else` raise at 270. There is
  no public single-step entry today.
- `step_condition_met?` (`when_context` gate) at **1511**, called at top of
  `execute_step` (76).
- `DEEP_QUERY_FN` (shadow/iframe-piercing) is a frozen heredoc constant at
  **15-36**, injected by `runtime_deep_call` (**1239**) and
  `runtime_shadow_eval` (**1031**). A `PageObserver` eval should ride
  `runtime_deep_call` to reuse it. All eval helpers go through
  `@session.send_command("Runtime.evaluate", { returnByValue: true,
  awaitPromise: true }, timeout: 10)` and `JSON.generate` their args
  (invariant 2 — the observer must too).
- **Stateful per-runner-instance flags** that reset if you build a new
  runner per step: `@recording_installed` (drives `drain_network_events`
  at 72), the debug recorder, `@last_error_signal_check`. → A held-open
  step session must **reuse one long-lived runner instance**, not one per
  action.
- `save_timeout_screenshot(description)` at **1161** currently **ignores
  `description`** and just calls `save_screenshot("timeout")`. Every call
  site already passes a descriptive string (lines 292, 367, 499, 597, 870,
  894, 916). This is the exact hook for `failures.ndjson`.
- `save_screenshot(label)` (**1125**) writes into `ENV["FREENTONIC_RUN_DIR"]`
  when set/writable, filename `#{run_id}-freentonic-#{label}-#{ts}.png`,
  mode `0600` (1135-1156). `failures.ndjson` sits next to it in the same dir.

### Stage lifecycle — `lib/freentonic/stages/connect.rb`

- `call` (**19**) branches: `interactive` (21), `recording` (29), normal
  `else` (45). Launch primitives: `launch_chrome` (94), `open_login_session`
  (111), `mask_webdriver` (121), `navigate_to_initial_url` (487).
- `run_pipeline` (**207-232**) builds a **new `BrowserWorkflowRunner` per
  phase**, all sharing the one `@session` and one persistent
  `workflow_context` hash — the template for a step driver.
- Teardown `ensure` (**64-77**): recorder → session → chrome → profile.
  A held-open session **cannot** live inside this single-`call` ensure; it
  needs its own lifecycle owner (a `StepDriver`/`StepSession` that closes
  Chrome on `DELETE`/EOF/idle-timeout).

### Selector heuristics — `lib/freentonic/recorder/probe.js`

- The whole file is **one anonymous IIFE (24-242)**; `selectorFor` (56),
  `nthChildPath` (122), `cssEscape` (115), `describeInputValue` (157),
  `visibleText` (46), `elementSummary` (175) all live **inside the closure**
  and are **not importable**. They are pure functions of `el`/`document`
  with no dependency on the recorder binding, so extraction is mechanical.
- **`describeInputValue` returns raw non-sensitive values** — an
  `inspect_page` inventory that must never log/leak values should reuse
  `selectorFor`/`elementSummary`/`visibleText` and the **`mask` flag** but
  **not** surface the `value`.

### Invoke server (the `/sessions` model) — `lib/freentonic/invoke_server.rb`

- Route dispatch: streaming routes matched first in `serve` (**381**),
  everything else → `dispatch` `case` on method+path (**560-585**). Add
  `/sessions` arms here.
- Bearer auth: `authenticated?` (**1390**, constant-time, OR over all
  tokens), `unauthorized` → 401 (**1417**). Every handler starts with
  `return unauthorized unless authenticated?(req)`.
- Serialization: `/invoke` is async — `handle_invoke` (**719**) returns 202
  queued; a **single worker thread** `run_worker` (**783**) runs the job
  inside `@invoke_mutex.synchronize` (**825**). One bank login at a time.
- **No server-level idle watchdog exists** — timeouts are per-connection
  read deadlines only (`READ_TIMEOUT`/`REQUEST_READ_DEADLINE = 30`). A
  held session that must auto-expire on inactivity has **no precedent to
  copy**; it needs its own idle timer. (This is the single biggest net-new
  piece of infrastructure in the whole feature.)

### Remote-prompt store — `lib/freentonic/remote_prompt_store.rb`

Filesystem rendezvous for mid-session OTP/SCA. The runner resolves it
lazily at `browser_workflow_runner.rb:845` from `ENV["FREENTONIC_RUN_DIR"]`.
A step session opened with a run dir keeps OTP/SCA working unchanged.

### Registry + tests

- Add `"inspect_page" => { required: [], optional: %w[as] }` to `SPECS`
  (`workflow_actions.rb:29-63`) **and** a `when "inspect_page"` arm in
  `execute_step` — the drift-guard test
  (`test/workflow_actions_test.rb:75-91`) fails otherwise.
- "Never log element values" is **runner convention, not enforced by the
  spec** — capture branches log counts/destinations only (e.g. `✓ #{name}:
  captured`, 408). `inspect_page` must follow suit.
- `FakeSession` (`test/browser_workflow_runner_test.rb:35-54`) duck-types
  the CDP session: records commands, returns `{"result"=>{"value"=>true}}`
  for `Runtime.evaluate` by default; tests override `send_command` to
  return a canned `value`. Seed an inventory JSON the same way.

## Implementation — Tier 1

### 1. Extract shared selector heuristics

Pull `selectorFor`, `nthChildPath`, `cssEscape`, `describeInputValue`,
`visibleText`, `elementSummary` out of the probe IIFE into a **shared
source string** both the recorder and a new `observe.js` inject. Options:
(a) a plain `.js` file both concatenate at load, or (b) a Ruby-side frozen
constant like `DEEP_QUERY_FN`. Prefer (a) for parity with `probe.js`.
Keep the probe's behavior byte-identical (its recording tests must stay
green — this is a pure refactor of that file).

### 2. `observe.js`

Injected snippet that walks visible interactive elements (`a`, `button`,
`input`, `select`, `[role=button]`), runs the shared `elementSummary`,
adds `type`/`label` for inputs, sets `masked: true` (from
`describeInputValue`) **without a value**, and returns
`{ url, title, interactive: [...] }`. Pierce shadow/iframes via
`DEEP_QUERY_FN`.

### 3. `Freentonic::PageObserver`

`PageObserver.observe(session)` runs the eval through the
`runtime_deep_call`-style path, parses the JSON, returns the hash.
Request/response — no binding channel needed (unlike the recorder).

### 4. `inspect_page` action

- Register in `SPECS` + add `when "inspect_page"` in `execute_step`:
  call `PageObserver.observe(@session)`, store into `@context[as.to_s]`
  when `as:` given, print an inventory **count** (never values) to the log,
  and `reporter.step(...)`.

### 5. `failures.ndjson` (machine-actionable failures)

In `save_timeout_screenshot(description)` (1161), after the screenshot,
call `PageObserver.observe` and append a line to
`<run_dir>/failures.ndjson` (mode 0600, same dir logic as `save_screenshot`)
containing: `t`, `description` (now used!), current URL/title, and the
near-miss `interactive` inventory. No field values — selectors/labels
only. Wrap in `rescue StandardError` like the screenshot path so a failing
observation never masks the original error.

## Implementation — Tier 2

### 6. Public per-step entry on the runner

Add a **public** `run_action(step_hash)` that wraps the private
`execute_step`, catching `UserError` / `ChromeCdp::Error` / `KeyError` and
returning an envelope instead of raising:

```ruby
def run_action(step)
  execute_step(step)
  { ok: true, action: step["action"] }
rescue UserError, ChromeCdp::Error, KeyError => e
  { ok: false, action: step["action"], error: e.message,
    observation: safe_observe }   # Tier-1 obs so the next guess is informed
end
```

Validate the action against `WorkflowActions` (registered name + required
keys) **before** dispatch — never execute an unregistered action (security).

### 7. `StepDriver` / `Stages::Connect` step mode

A new `step` branch in `connect.rb#call` (sibling to interactive/recording)
that runs `launch_chrome → open_login_session → mask_webdriver →
navigate_to_initial_url`, constructs **one** long-lived
`BrowserWorkflowRunner` against `@session`, and hands control to a driver
idle loop instead of `run_pipeline`. The driver owns teardown (close
session, recorder, isolated profile) on EOF/`DELETE`/idle-timeout —
reusing the same cleanup the `ensure` block does, but on its own lifecycle.

### 8a. CLI REPL — `--step`

`freentonic --step --workflow draft.yml`: launch as Connect does, navigate
to the initial URL, then read one action per line from stdin (a YAML
fragment or bare `action: ...`), `run_action` it, print the result
envelope as JSON to stdout, loop. `EOF`/`quit` → clean teardown. Add
`--step` in `cli.rb` alongside `--interactive`/`--recording` (137) and to
the mutual-exclusion guard (205-207).

### 8b. Server sessions

Mirror the shape onto `invoke_server.rb`:

- `POST /sessions {workflow, ...}` → `201 {session_id}` — open+hold a
  Chrome+CDP session. **Enforce the same one-at-a-time guarantee** as
  `/invoke`: a held session counts against `@invoke_mutex` (or an
  equivalent single-session guard); a second open is rejected/queued.
- `POST /sessions/:id/step {action, ...}` → the envelope from step 6.
  Validate through `WorkflowActions`; never accept arbitrary Ruby.
- `GET /sessions/:id/page` → a Tier-1 observation.
- `DELETE /sessions/:id` → close Chrome, clean profile.
- All behind the same bearer auth (`return unauthorized unless
  authenticated?`).
- **New: per-session idle timer** (no precedent — build it). A watchdog
  thread that `DELETE`s a session after N seconds of no `/step`/`/page`,
  so an abandoned session can't pin Chrome forever. `DELETE`-on-shutdown
  drains held sessions in the existing shutdown path.
- A session opened with `recording: true` also captures every step
  (reuses the recorder); OTP/SCA still work via the remote-prompt store.

## Tests

### Tier 1 (`test/page_observer_test.rb`, runner test additions)

- `test_inspect_page_returns_interactive_inventory` — `FakeSession` seeded
  with a canned `Runtime.evaluate` inventory; assert parsed inventory and
  that **no element values** appear.
- `test_inspect_page_marks_sensitive_inputs_masked` — password field →
  `masked: true`, no value.
- `test_inspect_page_logs_counts_not_values` — stdout has a count, never a
  field value.
- `test_timeout_writes_failure_observation` — a `wait_for_selector` timeout
  writes a `failures.ndjson` line with the inventory (and `description`),
  mode 0600.
- Probe refactor: existing `recorder`/probe tests stay green (proves the
  extraction was behavior-preserving).

### Tier 2

- `test_run_action_ok_envelope` / `test_run_action_error_envelope` —
  `{ok:true}` on success, `{ok:false, error:, observation:}` on a missing
  selector; **never raises**.
- `test_step_session_reuses_one_runner_across_actions` — two actions share
  `@context` (a `capture_url` then a `when_context` gate reading it).
- `test_step_rejects_unknown_action` — unregistered action → error
  envelope, no dispatch.
- Server (mirror `invoke_server_test.rb` stdlib patterns, no real Chrome):
  `test_sessions_lifecycle` (open → step → page → delete),
  `test_step_requires_auth`, `test_step_rejects_unknown_action`,
  `test_second_open_session_is_serialized_or_rejected`,
  `test_idle_session_times_out_and_frees_chrome`.

> Note (AGENTS.md invariant 10): tests run **without Chrome**. Tier-2
> server tests must stub the session/runner layer (as `invoke_server_test`
> stubs the runner), not launch a browser. The true end-to-end
> browser-drive belongs to the P2 "fake bank + one real-Chrome test" item,
> out of scope here.

## Docs / SECURITY

- README: `inspect_page` action + `--step` flag; `/sessions` endpoints in
  the invoke-server API doc.
- SECURITY.md: a step session is arbitrary registered-action execution
  against a live bank session (same trust level as running a workflow) —
  behind bearer auth, registered actions only, one-at-a-time, idle-bounded.
  `inspect_page`/`failures.ndjson` carry element **metadata, never values**.

## Risks / decisions

- **Idle watchdog is genuinely new infra** — the server has no idle-shutdown
  precedent. Scope it carefully; it is the resource-exhaustion boundary.
- **Probe IIFE extraction** touches the recorder's crown-jewel selector
  logic — keep it a pure refactor, lean on the existing recorder tests.
- **One-session-at-a-time vs. pool** — the proposal says one at a time
  (reuse invoke serialization). No unbounded pool. Confirm that's the
  desired constraint for the autonomous path.
- **Split delivery:** strongly recommend landing **Tier 1 as its own
  branch/PR** (small, useful immediately) before Tier 2. Confirm with user.

## Completion checklist (AGENTS.md)

- [ ] `bundle exec rake test` green (probe refactor didn't regress recording).
- [ ] `../freentonic-providers` `rake test` green.
- [ ] JS injection routed through `runtime_deep_call` / `JSON.generate`
      (invariant 2); no runtime gem (5); no unregistered-action execution.
- [ ] README + invoke-server API doc + SECURITY.md updated.
- [ ] Branch(es) handed back.

**Estimated effort:** Tier 1 ~1–1.5 days (probe extraction + observer +
action + failures.ndjson + tests). Tier 2 ~3–4 days (public entry + step
driver + CLI REPL + server endpoints + idle watchdog + tests). Land Tier 1
first.
