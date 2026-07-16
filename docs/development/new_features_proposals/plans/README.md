# Implementation plans — autonomous workflow-authoring loop

One plan per open proposal in
[`../`](../README.md). Each plan was verified against the working tree
(freentonic v0.18.1) — the proposals' file/line references had drifted, so
the plans carry the **current** anchors and flag every place a plan
diverges from its proposal.

| Plan | Proposal | Depends on | Rough effort |
| --- | --- | --- | --- |
| [`plan-schema-json-export.md`](plan-schema-json-export.md) | `--schema-json` | — (ship first) | ~0.5 day |
| [`plan-compile-recording.md`](plan-compile-recording.md) | `--compile-recording` | schema-json (soft) | ~1–2 days |
| [`plan-incremental-step-session.md`](plan-incremental-step-session.md) | `inspect_page` + `--step` | schema-json; compile (soft) | ~1.5 (Tier 1) + ~3–4 (Tier 2) days |
| [`plan-authoring-container.md`](plan-authoring-container.md) | `author` container | none hard; best after compile + step | ~1 day (Tier 1) |

## Suggested order

Matches the review's P0 → P1 → P2 sequencing
([`../../../llm-workflow-authoring-review.md`](../../../llm-workflow-authoring-review.md)):

1. **`--schema-json`** — smallest diff, prerequisite contract for the rest.
2. **`--compile-recording`** — turns an existing artifact into a runnable
   draft; highest value-per-diff.
3. **`inspect_page` + `--step`** — Tier 1 (observation + `failures.ndjson`)
   first, then Tier 2 (held-open session). The architectural centerpiece.
4. **`author` container** — packages the above into one command. Tier 1 is
   useful the day it lands (works with today's `--recording`/`--lint`).

## Cross-cutting corrections found during verification

These bite more than one plan — worth internalizing before starting:

- **`--compile-recording` and `--step` do not exist yet.** They appear only
  in proposal docs. The `author`-mode proposal's inner-loop examples call
  them, so its docs/examples must not promise them until plans 2/3 land.
- **The probe's `kind: "skipped"` event is aspirational** — the header
  comment describes it but `probe.js` never emits it. Only four probe kinds
  are real: `click`, `fill`, `submit`, `probe_ready`.
- **The `when_context` operator set is duplicated and not exposed as data**
  (`browser_workflow_runner.rb#compare_context` + `extract_plan/when_gate.rb`);
  the plan-verb sets, by contrast, are already clean frozen constants
  (`WorkflowSchema::PLAN_STEP_VERBS` etc.).
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
