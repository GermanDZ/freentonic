# Project Review — Debug / Record / Replay for LLM-Driven Workflow Authoring

Review of freentonic v0.18.1 (commit 8cebfd6) focused on one question:
**what is missing for an LLM to drive freentonic autonomously and write a
provider's `workflow.yml` by observing a real browser session?** Full
codebase pass (lib ~14k LoC, tests ~15k LoC, 1069 tests green) plus an
inventory of every existing debugging, recording, replay, and authoring
capability.

## Where the project stands

The previous review cycle is fully closed: all 21 items in
[`suggested-enhancements.md`](suggested-enhancements.md) are Done per
[`enhancements-tracking.md`](enhancements-tracking.md), including the
action registry, `--lint`, async `/invoke`, structured Reporter events,
container hardening, and the declarative `extract: plan:` /
`normalize: plan:` layers. Provider Ruby is now gated behind
`FREENTONIC_ALLOW_PROVIDER_RUBY`; three of four real providers ship zero
extractor Ruby. Test suite: 1069 runs / 2666 assertions, green (one
intermittent invoke-server timing test; the timezone tests require the
dev-only `tzinfo` gem and error rather than skip when it's absent).

Code health is strong: no TODO/FIXME debt, near-1:1 test-to-code ratio,
consistent typed errors, strict secret-file discipline (0600 everywhere),
and the security invariants in SECURITY.md continue to hold in code.

## Inventory: what already exists for the authoring loop

The building blocks for LLM authoring are ~70% present — and notably,
they were each built *for* this purpose (the proposals in
`docs/development/new_features_proposals/completed/` say so explicitly):

| Capability | Where | What it gives an LLM |
| --- | --- | --- |
| `--lint` | `linter.rb` | Millisecond validation of a drafted YAML without touching the bank: schema, action names/keys, ruby class resolution, `credentials.require` ⇔ `capture as:` cross-ref, `secret()` ⇔ `secrets:` cross-ref |
| Action registry | `workflow_actions.rb` (`SPECS`) | Single source of truth for all 33 actions + required/optional keys; drift-guarded against the runner |
| `--recording` mode | `recorder.rb`, `recorder/probe.js` | Human walks the bank UI; probe emits `click`/`fill`/`submit`/`navigate` JSONL with **derived CSS selectors, a `selector_strategy` (id → data-testid → name → aria-label → nth-child), and a `needs_review` flag**; sensitive inputs masked in-page |
| `record_requests` / `dump_requests` | `browser_workflow_runner.rb`, `debug_request_writer.rb` | Filtered network capture (NDJSON or HAR-with-bodies) from inside a workflow run — no DevTools dance |
| `pause` action | runner + `RemotePromptStore` | Mid-run handoff: human (or another agent via the server prompt API) drives while recording continues |
| `capture_url`, `screenshot`, timeout screenshots, `error_signals` | runner | Partial observability on failure |
| Reporter | `reporter.rb` | Typed NDJSON event stream (`stage.*`, `phase.*`, `step`) per run under `FREENTONIC_RUN_DIR` |
| Invoke server | `invoke_server.rb` | Headless orchestration surface: async `/invoke`, run log with Range polling, `/runs/:id/recording`, remote prompts for OTP/SCA/pause |
| `HarAnalyzer` | `providers/har_analyzer.rb` | HAR → endpoints/auth-headers/pagination report for drafting `api_client:` |
| `Scaffold` | `providers/scaffold.rb` | Provider directory template with authoring rules baked into comments |
| `--dump-raw` / `--from-raw` | `engine.rb` | Offline iteration on extract/normalize/export without re-login |

## The gap, precisely

Everything above supports a **human-in-the-loop, batch-shaped** loop:
run whole YAML → fail → read artifacts → edit → re-run. An LLM authoring
autonomously needs a **closed observe → act → observe loop** and
**compilers between the artifacts that already exist**. Concretely, five
things are missing:

1. **No structured page observation.** Screenshots are pixels; an LLM
   working over the invoke server needs *text*: current URL, title, and
   an inventory of visible interactive elements *with YAML-ready
   selector candidates*. The selector heuristics already exist — in
   `probe.js#selectorFor` — but only fire on human interaction events,
   never on demand.
2. **No incremental execution.** The unit of execution is a whole
   workflow run. A wrong selector guess on step 7 costs a full re-login
   (and burns 2FA patience / anti-bot budget). There is no way to hold a
   session open and try one action at a time.
3. **Nothing consumes `recording.jsonl`.** The recorder emits
   selector-annotated events explicitly designed to become YAML
   ("substitute `secret(...)` if it knows the name" — `recorder.rb:20`),
   but the translation to a `pipeline:` draft is entirely manual/LLM
   freehand. Same for `HarAnalyzer`: it prints a human report, not an
   `api_client:` skeleton.
4. **Failure output is not machine-actionable.** A timeout yields a
   screenshot + "wait_for_selector timed out". The information an LLM
   needs to self-correct — what *was* on the page, which near-miss
   selectors existed — is discarded.
5. **No safe practice environment.** Nothing end-to-end drives real
   Chrome in CI; the browser layer is tested only through `FakeSession`.
   An LLM (or CI) has no bank-shaped sandbox to iterate against, so
   every experiment touches a real provider.

## Recommendations

### P0 — Compilers and observability (small diffs, existing building blocks)

#### 1. `--schema-json`: export the action dialect machine-readably
Emit `WorkflowActions::SPECS` (+ per-action one-liners, + the
`extract: plan:` / `normalize: plan:` verb grammars and `when_context`
operators) as JSON on stdout. This is the system-prompt payload for any
authoring agent, always in lockstep with the installed version — no more
pasting 27 doc pages. Cheap: the registry is already the single source
of truth, and its own comment says it "can later drive generated action
docs". Do the doc generation at the same time and delete the drift risk.

#### 2. `recording.jsonl → workflow.yml` draft compiler
`freentonic --compile-recording PATH [--workflow existing.yml]`:
deterministic translation of the probe event stream into a draft
`connect:` pipeline —

- `navigate` event → `navigate` (first) / `wait_url` (subsequent);
- `fill` with `mask: true` → `fill` with `value: secret(REPLACE_ME)`
  plus a generated `secrets:` entry;
- `fill` (unmasked) → `fill` with the literal, flagged for review;
- `click`/`submit` → `click`, preceded by `wait_for_selector` on the
  target selector so the draft is robust by construction;
- events whose selector carries `needs_review: true` (the `nth-child`
  fallback strategy) get an inline `# REVIEW:` comment.

The output is a *draft*, never a finished provider — but it turns the
recorder's already-annotated events into a runnable, `--lint`-clean
starting point instead of freehand YAML. The masking metadata the probe
already ships (`describeInputValue`) is exactly what lets the compiler
place `secret(...)` correctly. Pairs with `--lint` as the immediate
next step in the loop.

#### 3. `HarAnalyzer` → `api_client:` skeleton (not just a report)
`HarAnalyzer` already extracts endpoints (UUIDs generalized to `{id}`),
ranked auth headers, login-POST key names, and pagination params
(`providers/har_analyzer.rb`). Today it emits a human report. Add an
`--emit api_client` mode that renders the same analysis as a draft
`api_client:` block — `base_url`, `define_get`/`define_post` stubs with
`{param}` templating, `auth_header` lines for the non-browser headers,
and a `pagination:` guess when offset/cursor params are detected. Same
review-not-truth contract as #2.

While here, wire up the entry points the CHANGELOG already advertises:
`rake har[file]` and `rake new[provider]` are referenced in
`CHANGELOG.md:1039,1043` and in the scaffold template comment
(`scaffold.rb:122`) but the current `Rakefile` defines only `:test` —
both classes are reachable only by hand-written Ruby. Expose them as
rake tasks (or `freentonic --har` / `freentonic --scaffold` subcommands,
which an agent can call directly) and the doc drift closes.

#### 4. Machine-actionable failure output
Every wait action already takes a screenshot on timeout
(`save_timeout_screenshot`). At the same site, capture a JSON failure
record into the Reporter stream / a `<run_dir>/failures.ndjson` artifact:
current URL, page title, the expected selector, and a **near-miss
inventory** — the visible interactive elements and their candidate
selectors (reusing `probe.js#selectorFor`, see P1 #5). That is precisely
the context an LLM needs to self-correct a bad selector guess without a
human reading pixels. Screenshots stay for humans; the NDJSON is for the
agent.

### P1 — The closed observe → act → observe loop (higher leverage)

#### 5. On-demand page observation (`inspect_page`)
The selector heuristics in `probe.js#selectorFor` are the crown jewel of
the recorder, but they only fire on human interaction events. Expose
them on demand: an `inspect_page` workflow action (and a matching
`GET /runs/:id/page` server endpoint for the headless path) that returns
structured text — URL, title, and an inventory of visible interactive
elements each with its YAML-ready selector candidate, `selector_strategy`,
and `needs_review` flag. This is the single most useful primitive for an
authoring agent: it replaces "take a screenshot and guess" with "here are
the buttons and their selectors." It also backs the near-miss inventory
in #4.

#### 6. Incremental execution — hold the session open
Today the unit of execution is a whole workflow run; a wrong guess on
step 7 costs a full re-login and burns 2FA / anti-bot budget. Add a mode
that keeps one Chrome + CDP session open and executes **one action at a
time**, returning the result (and, ideally, a #5 observation) after each.
Two shapes, same engine:

- **CLI REPL** — `freentonic --step --workflow draft.yml` reads one
  action (YAML or a bare `action:` line) from stdin, runs it against the
  live session, prints the outcome, loops. The human/agent iterates a
  selector in seconds instead of minutes.
- **Server session** — `POST /sessions` opens a held session,
  `POST /sessions/:id/step` submits one action, `DELETE` closes it. This
  is the autonomous-agent surface; it reuses the existing prompt/recording
  plumbing.

`BrowserWorkflowRunner#execute_step` is already per-action and stateless
between steps against a persistent `@session`, so the engine change is
small — the work is the session-lifecycle wrapper and holding Chrome
open past a single phase. This closes the observe→act→observe loop that
gaps #1 and #2 identified.

#### 7. Correlated recording (DOM events × network on one timeline)
`--recording` (DOM events) and `record_requests` (network) are separate
streams. For authoring, their *correlation* is the payload: "clicking
this button fired these API calls and this bearer token appeared in a
response header" is simultaneously the `connect:` step **and** the
`api_client:` endpoint **and** the `capture_*` action. Merge both streams
into one timestamp-ordered timeline (both already carry `t` in ms) so a
compiler — or an LLM reading the JSONL — can draft `connect` and
`api_client` together instead of reverse-engineering the link. This is
the piece that takes #2 and #3 from "two independent drafts" to "one
coherent provider draft."

### P2 — Practice environment and robustness

#### 8. A bank-shaped sandbox + one real-Chrome end-to-end test
The browser layer is tested only through `FakeSession`; nothing drives
real Chrome in CI, and there is no bank-shaped target to iterate against,
so every authoring experiment touches a real provider. Ship a tiny static
"fake bank" (a login form, a fake SCA step, a couple of JSON API
endpoints with cursor pagination) servable from stdlib `WEBrick`/`Socket`,
plus **one** end-to-end test that launches headless Chrome, runs a
checked-in workflow against it, and asserts the canonical envelope. This
gives CI its first true browser-layer coverage and gives an authoring
agent (or a human) a safe place to practice the whole loop — connect,
capture, extract, normalize — with zero real-bank risk. It also makes #5
and #6 demonstrable end-to-end rather than fake-session only.

#### 9. Verbose / CDP wire-tracing mode
There is no `--verbose` and no CDP frame logging anywhere
(`chrome_cdp.rb`'s WebSocket layer is silent). A `--trace-cdp` flag that
logs outbound commands and inbound events (values redacted) to
`<run_dir>/cdp.ndjson` would make "why did this action not do what I
expected" answerable without a debugger — valuable to both a human and an
agent diagnosing a failed draft.

## Health items to fix in passing

These are small and independent of the roadmap above:

- **`tzinfo` tests error instead of skipping when the gem is absent.**
  With a bare `ruby -Ilib -Itest` run (no bundler), the timezone/helpers
  tests raise `UserError` and two assertions fail on a message-substring
  mismatch (5 red). Under `bundle exec` (tzinfo installed) the suite is
  green. Named-zone tests should `skip` when `tzinfo` can't load, so the
  suite is green on a plain stdlib checkout — matching the "zero runtime
  deps" story. (`test/timezone_test.rb`, `test/helpers_test.rb`.)
- **Flaky invoke-server test.** `InvokeServerTest#test_unknown_path_is_404`
  intermittently raises `Errno::EBADF` from `Net::HTTP` teardown (~1 run
  in 4). A test-harness socket-lifecycle race, not a product bug, but it
  makes the suite non-deterministic. Worth pinning down the client-close
  ordering in the test helper. (`test/invoke_server_test.rb:77`.)

## Suggested sequencing

1. **P0 #1 (`--schema-json`)** and the **health items** first — hours of
   work, and #1 is a prerequisite for any agent authoring against the
   installed version.
2. **P0 #2–#4** next: the two compilers and machine-actionable failures
   turn artifacts that already exist into runnable drafts. Highest
   value-per-diff on the board.
3. **P1 #5 → #6 → #7**: build observation first (it backs everything),
   then incremental execution, then correlation. This is where freentonic
   goes from "human-in-the-loop batch" to "closed autonomous loop."
4. **P2** last: the sandbox makes the whole thing testable and safe to
   practice against; it's also the natural home for the first real-Chrome
   CI coverage the project currently lacks.

The through-line: freentonic already *observes* everything an LLM needs
(selectors, network, credentials, events) — the missing work is
**compilers between those observations and YAML**, and a **held-open
session** so the agent can act on what it observes one step at a time.