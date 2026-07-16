# Implementation plan — `--schema-json` (dialect export)

Plan for [`proposal-schema-json-export.md`](../proposal-schema-json-export.md).
Ground-truth verified against the working tree (freentonic v0.18.1); the
proposal's line references have drifted, so this plan carries the
**current** anchors.

## Goal

One new short-circuit flag, `freentonic --schema-json`, that prints the
whole workflow dialect (action names + required/optional keys + one-line
summaries, universal keys, `when_context` operators, and the
`extract`/`normalize`/`elevate` plan-verb sets) as a single version-locked
JSON document to stdout and exits 0. No `--workflow`, no Chrome, no
network. It is the system-prompt payload for any authoring agent, always
in lockstep with the installed gem.

## Sequencing

**Ship this first.** It is the smallest diff and the prerequisite for the
other three authoring features (they all want a stable machine-readable
contract of "what actions exist and what keys they take"). No dependency
on any other plan.

## Ground truth (verified anchors)

| Thing | Location | Note |
| --- | --- | --- |
| Action registry `SPECS` | `lib/freentonic/workflow_actions.rb:29-63` | 33 actions, each `{ required:, optional: }`. **No `summary`/`doc` field today.** |
| `UNIVERSAL_KEYS` | `workflow_actions.rb:23` | `%w[action when_context]` |
| Registry public API | `workflow_actions.rb:65-81` | `names`, `known?`, `required_keys`, `optional_keys` |
| `when_context` operators | inline `case` in `browser_workflow_runner.rb#compare_context:1531-1544` | `gt gte lt lte eq neq present absent` — **not exposed as data** |
| duplicate operator set | `extract_plan/when_gate.rb#compare:24-36` | same 8 ops; header says it "reuses the workflow's `when_context` operator set" |
| extract plan verbs | `WorkflowSchema::PLAN_STEP_VERBS` (`workflow_schema.rb:424-425`) | already a clean frozen array — read it |
| normalize plan verbs | `WorkflowSchema::NORMALIZE_PLAN_VERBS` (`workflow_schema.rb:430`) | `PLAN_STEP_VERBS - %w[fetch]` |
| elevate plan verbs | `WorkflowSchema::ELEVATE_STEP_VERBS` (`workflow_schema.rb:457-458`) | `PLAN_STEP_VERBS + await_operator_approval + rebind_credential` |
| seed bindings / output keys | `workflow_schema.rb:436-447` | `NORMALIZE_SEED_BINDINGS`, `NORMALIZE_OUTPUT_KEYS`, `PLAN_SEED_BINDINGS` |
| dialect version `1` | bare literal in `workflow_schema.rb:280-285` | **no constant** — introduce one |
| library version | `VERSION` in `lib/freentonic/version.rb:4` (`"0.18.1"`) | emitted by CLI at `cli.rb:140` |
| CLI `--lint` model | `opts.on` at `cli.rb:131`; short-circuit `run` at `cli.rb:31`; handler `run_lint` at `cli.rb:235-242` | copy this shape |
| existing drift-guard | `test/workflow_actions_test.rb:75-91` | registry ↔ runner action names only; nothing locks operators/verbs yet |

Correction vs. proposal: it says "all 33 actions" and "// ... all 33
actions" — confirmed 33. It also assumes `optional` is already present
everywhere; it is omitted on entries with no optional keys (e.g. `note`),
so the emitter must default a missing `:optional` to `[]`.

## Implementation steps

### 1. Add `summary:` to every `SPECS` entry — `workflow_actions.rb`

Add a `summary:` string (one line, imperative, ≤ ~90 chars) to each of the
33 entries. Source the sentences from the existing per-action docs
(`docs/workflow-action-*.md`) / `docs/workflow-actions.md` so they match
the prose. Leave `doc:` optional — populate it with the doc filename where
one exists (`"workflow-action-navigate.md"`), omit otherwise; the exporter
emits `doc` only when present.

Shape after:

```ruby
"navigate" => { required: %w[url], summary: "Page.navigate to a URL.",
                doc: "workflow-action-navigate.md" },
```

This is mechanical but touches all 33 rows. Keep `required`/`optional`
exactly as-is (they are a public contract — invariant 9-adjacent).

### 2. Introduce named constants for the two non-enumerable sources

Both are "independently good" refactors the proposal calls for (turn a
`case` into a table, the way `WorkflowActions` already did):

- **`when_context` operators.** Add a frozen constant listing the 8
  operator names and make both `compare_context`
  (`browser_workflow_runner.rb:1531`) and `WhenGate.compare`
  (`when_gate.rb:24`) validate/read against it. Minimum viable: define
  `Freentonic::WhenContext::OPERATORS = %w[gt gte lt lte eq neq present
  absent].freeze` in a tiny new file (or as a constant on an existing
  shared module) and have `SchemaExport` read it. **Keep the `case`
  dispatch** — just add a drift-guard test asserting the `case` arms
  equal the constant (mirrors `test_registry_matches_runner_dispatch_actions`).
  Do **not** rewrite the numeric-comparison semantics; `WhenGate` compares
  against a raw operand and the runner coerces via `numeric!` — leave that
  behavior untouched, this is names-only.
- **dialect version.** Add `Freentonic::WorkflowSchema::DIALECT_VERSION = 1`
  and change the literal check at `workflow_schema.rb:280-285` to reference
  it. `SchemaExport` emits `workflow_schema_version: DIALECT_VERSION`.

Plan verbs need **no** refactor — `PLAN_STEP_VERBS` / `NORMALIZE_PLAN_VERBS`
/ `ELEVATE_STEP_VERBS` are already frozen arrays. Read them directly.

### 3. New `Freentonic::SchemaExport` — `lib/freentonic/schema_export.rb`

Pure assembly, stdlib `json` only (already a load-time dependency; **no new
gem** — invariant 5). Public `SchemaExport.to_json` returns a pretty JSON
string built from a plain Hash:

```ruby
module Freentonic
  module SchemaExport
    module_function

    def document
      {
        "freentonic_version" => Freentonic::VERSION,
        "workflow_schema_version" => WorkflowSchema::DIALECT_VERSION,
        "actions" => WorkflowActions::SPECS.transform_values { |s|
          {
            "required" => Array(s[:required]),
            "optional" => Array(s[:optional]),
            "summary"  => s.fetch(:summary),
          }.tap { |h| h["doc"] = s[:doc] if s[:doc] }
        },
        "universal_keys" => WorkflowActions::UNIVERSAL_KEYS,
        "when_context_operators" => WhenContext::OPERATORS,
        "extract_plan_verbs"   => WorkflowSchema::PLAN_STEP_VERBS,
        "normalize_plan_verbs" => WorkflowSchema::NORMALIZE_PLAN_VERBS,
        "elevate_plan_verbs"   => WorkflowSchema::ELEVATE_STEP_VERBS,
        "plan_seed_bindings"      => WorkflowSchema::PLAN_SEED_BINDINGS,
        "normalize_seed_bindings" => WorkflowSchema::NORMALIZE_SEED_BINDINGS,
        "normalize_output_keys"   => WorkflowSchema::NORMALIZE_OUTPUT_KEYS,
      }
    end

    def to_json(*)
      JSON.pretty_generate(document)
    end
  end
end
```

Add `require_relative "freentonic/schema_export"` to `lib/freentonic.rb`.

> Decision point: the proposal's example shows `extract_plan_verbs` as an
> object with per-verb `keys`. The registry does **not** currently store
> per-verb key sets for plan verbs (validation lives in
> `WorkflowSchema#validate_plan_step!`, not a table). Emitting the verb
> **names as arrays** (as above) is the honest, drift-free MVP. Emitting
> per-verb key schemas is a real extension (it needs a verb→keys table
> that doesn't exist yet) — call it out and defer unless the user wants it.

### 4. Wire the flag — `cli.rb`

- Add `schema_json: false` to the options hash (near `cli.rb:89`).
- Add the `opts.on` next to `--lint` (`cli.rb:131`):
  ```ruby
  opts.on("--schema-json", "Print the workflow dialect (actions, keys, plan verbs) as JSON and exit") { options[:schema_json] = true }
  ```
- Short-circuit in `#run` **before `validate!`** (it needs no `--workflow`,
  unlike `--lint`), returning through a small handler for testability:
  ```ruby
  return run_schema_json(options) if options[:schema_json]   # before validate!
  ```
  ```ruby
  def run_schema_json(_options)
    require_relative "schema_export"
    @stdout.puts Freentonic::SchemaExport.to_json
    0
  end
  ```

## Tests (`test/schema_export_test.rb` + additions)

Follow AGENTS.md conventions (no network, no Chrome, stdlib only):

- `test_schema_json_lists_every_registered_action` — exported `actions`
  keys `== WorkflowActions.names` (drift guard: can't omit/invent).
- `test_schema_json_required_keys_match_registry` — per action, exported
  `required == WorkflowActions.required_keys(name)` and
  `optional == WorkflowActions.optional_keys(name)`.
- `test_every_action_has_a_summary` — every `SPECS` value has a non-empty
  `:summary` (locks the new field so a future action can't skip it).
- `test_schema_json_includes_plan_verbs_and_operators` — `extract_plan_verbs`,
  `normalize_plan_verbs`, `when_context_operators` present and non-empty,
  and `normalize_plan_verbs` excludes `fetch`.
- `test_when_context_operators_match_dispatch` — new drift guard: the
  `OPERATORS` constant equals the operator names scanned out of
  `compare_context` (mirror the registry↔runner regex test).
- `test_schema_json_is_valid_json_and_exits_zero` — run the CLI with
  `--schema-json`, `JSON.parse` stdout, assert exit 0 and no Chrome/network.
- `test_dialect_version_constant_matches_validate` — a `version: 2`
  workflow still raises, and the constant is `1`.

## Docs

- README: add `--schema-json` to the CLI flag list; one line on what it emits.
- Optional (proposal follow-up, **not** required to ship): a
  `--schema-json --format markdown` / rake task that regenerates the 27
  `docs/workflow-action-*.md` stubs from the table — deletes the
  registry↔runner↔docs drift for good. Defer to a follow-up.

## Risks / decisions

- **Per-verb key schemas for plan verbs** (proposal's richer shape) don't
  exist as data — emit verb-name arrays now, defer the table. *Confirm
  with user whether names-only is acceptable for v1.*
- Adding `summary:` to 33 rows is the bulk of the diff; low risk, but keep
  `required`/`optional` byte-identical.
- Refactoring the operator `case` to read a constant is names-only —
  **do not** touch the numeric coercion semantics (`numeric!` vs raw).

## Completion checklist (AGENTS.md)

- [ ] `bundle exec rake test` green.
- [ ] `../freentonic-providers` `rake test` green (no behavior change, but run it).
- [ ] No runtime gem added.
- [ ] README updated (new CLI flag = public surface).
- [ ] Branch handed back; no PR/push/tag by the agent.

**Estimated effort:** ~half a day. Biggest chunk is writing 33 good
one-line summaries; the code is ~60 lines + tests.
