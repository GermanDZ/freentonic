# Feature proposals

Design proposals for framework capabilities, in the format
[`AGENTS.md`](../../../AGENTS.md) expects (motivation → why-framework →
scope/tiers → implementation → security → tests). A framework-agent
implements these; on completion they move to
[`completed/`](completed/).

## Open drafts

The four below form the MVP of the **autonomous workflow-authoring
loop** analyzed in
[`docs/llm-workflow-authoring-review.md`](../../llm-workflow-authoring-review.md)
and sequenced in [`plans/README.md`](plans/README.md). **Status
(2026-07-16):** #1, #2, and #3's **Tier 1** are implemented on branch
`feat/authoring-loop-schema-compile-inspect`; #3's Tier 2 and #4 remain open.
They are independently shippable; the suggested order is:

1. **✅ Shipped.** [`proposal-schema-json-export.md`](proposal-schema-json-export.md) —
   `--schema-json`. Emit the action dialect (names, keys, plan verbs,
   `when_context` operators) as version-locked JSON. The system-prompt
   payload for any authoring agent. Smallest diff; unblocks the rest.
2. **✅ Shipped** (fresh-draft; graft mode deferred).
   [`proposal-recording-to-workflow-compiler.md`](proposal-recording-to-workflow-compiler.md) —
   `--compile-recording`. Deterministically translate a
   `recording.jsonl` into a `--lint`-clean draft `connect:` pipeline,
   masking credentials into `secret(...)` by construction.
3. **🚧 Tier 1 shipped** (`inspect_page` + `PageObserver` +
   `failures.ndjson`); **Tier 2 open** (`--step` / `/sessions`).
   [`proposal-incremental-step-session.md`](proposal-incremental-step-session.md) —
   `inspect_page` + held-open step execution (CLI `--step` and server
   `/sessions`). The closed `observe → act → observe` loop: try one
   action against a live session, get structured page observation back,
   iterate — instead of paying a full re-login per guess.
4. **⏳ Open.** [`proposal-authoring-container.md`](proposal-authoring-container.md) —
   an `author` container mode: one command mounts a writable workspace,
   serves noVNC on a fixed loopback port with a known password, and drops
   into an iterate loop where `--recording` / `--compile-recording` /
   `--lint` / `--step` all run against the mounted dir. The environment
   the three tools above run in; extends the existing
   `docker-run-freentonic.sh` and `docker-entrypoint.sh`.

## Completed

See [`completed/`](completed/) — `pause`, `record_requests` /
`dump_requests`, `prompt_stdin_and_fill`, and the `inline_fd` secret
backend. The drafts above build directly on that debug/record plumbing.
Proposals #1 and #2 (fully shipped) move here once
`feat/authoring-loop-schema-compile-inspect` merges to `main`; #3 stays open
until its Tier 2 lands.
