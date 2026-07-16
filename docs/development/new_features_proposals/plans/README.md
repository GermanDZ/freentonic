# Implementation plans — autonomous workflow-authoring loop

One plan per open proposal in
[`../`](../README.md). Each plan was verified against the working tree
(freentonic v0.18.1) — the proposals' file/line references had drifted, so
the plans carry the **current** anchors and flag every place a plan
diverges from its proposal.

## Status

_Updated 2026-07-16._ Deliverables **1–3 are implemented** on branch
`feat/authoring-loop-schema-compile-inspect` (code commit `affc168`; +42
tests, full suite green, `../freentonic-providers` green): `--schema-json`,
`--compile-recording` (fresh-draft), and `inspect_page` + `failures.ndjson`
(step-session **Tier 1**). Deliverables **4–5** — the held-open step session
(step Tier 2) and the `author` container — plus every fast-follow remain
**open**. See the ✅ / ⏳ column below.

| Plan | Proposal | Depends on | Rough effort |
| --- | --- | --- | --- |
| [`plan-schema-json-export.md`](plan-schema-json-export.md) | `--schema-json` | — (ship first) | ~0.5 day |
| [`plan-compile-recording.md`](plan-compile-recording.md) | `--compile-recording` | schema-json (soft) | ~1–2 days |
| [`plan-incremental-step-session.md`](plan-incremental-step-session.md) | `inspect_page` + `--step` | schema-json; compile (soft) | ~1.5 (Tier 1) + ~3–4 (Tier 2) days |
| [`plan-authoring-container.md`](plan-authoring-container.md) | `author` container | none hard; best after compile + step | ~1 day (Tier 1) |

## Recommended order

Six deliverables, not four: the two tiered plans (step-session, author)
split into independently-shippable pieces, and the split matters for
sequencing. This order follows the review's P0 → P1 → P2 framing
([`../../../llm-workflow-authoring-review.md`](../../../llm-workflow-authoring-review.md))
but interleaves the tiers so each ships the moment it's useful — smallest
diff and hardest dependency first, biggest architectural piece deferred
until its prerequisite (Tier 1 observation) exists.

| # | Deliverable | Status | Plan | Effort | Why here |
| --- | --- | --- | --- | --- | --- |
| 1 | **`--schema-json`** | ✅ shipped | schema-json | ~0.5d | P0. Smallest diff; the machine-readable dialect contract every other feature (and any authoring agent) reads. No dependencies — unblocks the rest. |
| 2 | **`--compile-recording`** (fresh-draft) | ✅ shipped | compile-recording | ~1d | P0, highest value-per-diff: turns a `recording.jsonl` freentonic *already* writes into a `--lint`-clean draft. Soft-depends on #1, no hard dep. Defer graft mode (see fast-follows). |
| 3 | **`inspect_page` + `failures.ndjson`** (step Tier 1) | ✅ shipped | incremental-step-session | ~1–1.5d | P0/P1 boundary. `PageObserver` backs everything downstream, and `failures.ndjson` is P0-value machine-actionable output on its own. Tier 2 hard-depends on it — so it ships as its own slot, not bundled with the REPL. |
| 4 | **Held-open step session** (`--step` + `/sessions`, step Tier 2) | ⏳ pending | incremental-step-session | ~3–4d | P1. The architectural centerpiece — closes `observe → act → observe`. Depends on #3. Carries the single biggest net-new infra: the per-session idle watchdog. |
| 5 | **`author` container** (Tier 1) | ⏳ pending | authoring-container | ~1d | Pure packaging; works with today's flags the day it lands, but *most* useful once #2/#4 exist (its inner loop calls `--compile-recording` / `--step`). Slot it here so its docs only promise shipped commands. |

**Critical path ≈ 6–8 days** (#1→#5). **#1–#3 are now done** — they landed
together on `feat/authoring-loop-schema-compile-inspect` rather than as three
separate branches. **Remaining:** #4 (~3–4d, the long pole, builds directly on
#3's `PageObserver`) and #5 (~1d).

### Fast-follows (off the critical path, land opportunistically)

- **`--compile-recording` graft mode** (`--workflow existing.yml`) — the
  fresh draft delivers most of the value; graft must preserve an existing
  file's comments (+0.5–1d). Fast-follow to #2.
- **`author` container Tier 2** (shared step-server port for the co-pilot
  loop) — additive; gated on #4. Must not block #5's Tier 1.
- **Docs regeneration from the registry** (`--schema-json --format
  markdown`) — kills the registry↔runner↔docs drift for good. Follow-up to #1.

## Cross-cutting corrections found during verification

These bite more than one plan — worth internalizing before starting:

- **`--compile-recording` now exists (deliverable 2); `--step` does not yet.**
  The `author`-mode proposal's inner-loop examples call both — its
  docs/examples may now promise `--compile-recording` but must still not
  promise `--step` until deliverable 4 lands.
- **The probe's `kind: "skipped"` event is aspirational** — the header
  comment describes it but `probe.js` never emits it. Only four probe kinds
  are real: `click`, `fill`, `submit`, `probe_ready`.
- **The `when_context` operator set was duplicated and not exposed as data**
  (`browser_workflow_runner.rb#compare_context` + `extract_plan/when_gate.rb`) —
  **addressed by deliverable 1**: both now validate against
  `Freentonic::WhenContext::OPERATORS`. The plan-verb sets were already clean
  frozen constants (`WorkflowSchema::PLAN_STEP_VERBS` etc.).
- **`Linter#run` returns an exit code (0/1), not an errors array.**
- **The invoke server has no idle watchdog** — only per-connection read
  deadlines. The step session's per-session idle timeout is net-new infra.
- **`FREENTONIC_VNC_PASSWORD` is not forwarded by `docker-run-freentonic.sh`
  today** — the `author` arm must pass it explicitly.
- **The Ruby git-refusal guard detects `.git` directories only** (misses
  linked worktrees); shell-side, use `git rev-parse --is-inside-work-tree`.
- **`FREENTONIC_RUN_DIR` is the universal artifact router** — pointing it at
  a writable mount sends `recording.jsonl`, screenshots, `events.ndjson`,
  and prompts there with no extra flags. Both the step-session
  (`failures.ndjson`) and author-container plans lean on this.

## House rules every plan follows

From [`../../../../AGENTS.md`](../../../../AGENTS.md): implement → register →
test → doc; **zero runtime gem dependencies**; JS injected into Chrome
serializes args via `JSON.generate` through the existing `runtime_*`
helpers; `YAML.safe_load` untouched; tests run without Chrome or network
(`FakeSession` + stdlib stubs); no PR/push/tag by the agent — hand back a
branch; validate against `../freentonic-providers` before calling it done.
