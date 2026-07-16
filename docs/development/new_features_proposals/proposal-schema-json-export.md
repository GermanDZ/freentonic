# Proposal — `--schema-json`: machine-readable dialect export

**Status:** draft. No dependencies; can ship independently and is a
prerequisite for any autonomous authoring agent. Smallest diff of the
"LLM authoring loop" set
([`docs/llm-workflow-authoring-review.md`](../../llm-workflow-authoring-review.md)
P0 #1).

**Motivation:** an LLM asked to author a `workflow.yml` today has to be
handed the dialect out-of-band — 27 `docs/workflow-action-*.md` pages,
the `extract: plan:` / `normalize: plan:` grammars, and the
`when_context` operator set — pasted into a system prompt and manually
kept in sync with the installed gem version. That is brittle (the docs
and the code drift) and expensive (thousands of tokens of prose the
agent must re-read). The action registry
([`workflow_actions.rb`](../../../lib/freentonic/workflow_actions.rb))
is already the single source of truth for action names and required
keys; its own comment says it exists so the table "can later drive
`--lint` and generated action docs". This proposal cashes that in: emit
the whole dialect as one JSON document, always in lockstep with the
installed version.

## Why this belongs in the framework

- The registry is framework-internal; only the framework can emit it
  authoritatively and version-locked. A hand-maintained schema in the
  providers repo would re-introduce the drift this closes.
- It is the foundation for the other authoring proposals
  (`--compile-recording`, `--step`): all three want a stable,
  machine-readable contract for "what actions exist and what keys they
  take."
- Near-zero surface: it reads existing constants and prints JSON. No
  Chrome, no network, no new trust boundary.

## Scope

One new flag, `--schema-json`, that prints a JSON document to stdout and
exits 0. Short-circuits like `--lint` does
([`cli.rb:31`](../../../lib/freentonic/cli.rb)) — no `--workflow`
required.

```sh
freentonic --schema-json > dialect.json
```

### Output shape

```json
{
  "freentonic_version": "0.18.1",
  "workflow_schema_version": 1,
  "actions": {
    "navigate": {
      "required": ["url"],
      "optional": [],
      "summary": "Page.navigate to a URL.",
      "doc": "workflow-action-navigate.md"
    },
    "fill": {
      "required": ["selector", "value"],
      "optional": ["clear"],
      "summary": "Human-typed fill of an input via CDP key events.",
      "doc": "workflow-action-fill.md"
    }
    // ... all 33 actions
  },
  "universal_keys": ["action", "when_context"],
  "when_context_operators": ["present", "absent", "eq", "gt", "lt", "..."],
  "extract_plan_verbs": {
    "fetch":    { "keys": ["endpoint", "args", "safe", "default", "on_error", "as"] },
    "for_each": { "keys": ["in", "as", "yield", "collect", "skip_when"] }
    // ...
  },
  "normalize_plan_verbs": { "...": {} }
}
```

## Implementation

Two pieces, both small.

1. **Add a `summary:` (and optional `doc:`) field to
   `WorkflowActions::SPECS`.** The 33 one-line summaries already exist in
   prose in `docs/workflow-actions.md` and the per-action pages — move
   the single-sentence version into the registry so it stays in lockstep
   with the code (the drift-guard test already locks the registry
   against the runner). `optional` keys are already documented there.

2. **Add `Freentonic::SchemaExport.to_json`** that assembles the
   document from:
   - `WorkflowActions::SPECS` (+ the new `summary`/`doc` fields) and
     `WorkflowActions::UNIVERSAL_KEYS`;
   - the `when_context` operator list (currently inline in
     `browser_workflow_runner.rb#step_condition_met?` — lift the operator
     names to a named constant so both the gate and the export read it);
   - the `extract: plan:` verb set from
     [`extract_plan/interpreter.rb`](../../../lib/freentonic/extract_plan/interpreter.rb)`#dispatch`
     and the `normalize: plan:` verbs from the normalizer plan
     interpreter (same treatment — a named `VERBS` constant the `case`
     dispatch and the export both consume).

3. **Wire the flag** in `Cli#parse` next to `--lint`
   ([`cli.rb:131`](../../../lib/freentonic/cli.rb)) and short-circuit in
   `Cli#run`:

   ```ruby
   opts.on("--schema-json", "Print the workflow dialect (actions, keys, plan verbs) as JSON and exit") { options[:schema_json] = true }
   ```
   ```ruby
   # in #run, before validate!/execute
   if options[:schema_json]
     @stdout.puts Freentonic::SchemaExport.to_json
     return 0
   end
   ```

The refactors in (2) — lifting the `when_context` operators and the plan
verbs to named constants — are independently good: they turn three
`case` statements into tables the way `WorkflowActions` already did for
action dispatch, and set up the "generate the docs from the table"
follow-up.

## Follow-up (not required to ship): generate the action docs

Once every action carries `summary`/`required`/`optional`/`doc` in the
registry, the 27 `docs/workflow-action-*.md` stubs can be emitted from
the table (`freentonic --schema-json --format markdown`, or a rake
task). That deletes the last drift risk between the three parallel
structures (registry, runner, docs) the previous review flagged.

## Security considerations

None new. The output is the static dialect definition — no workflow
content, no captured data, no secrets. It is safe to emit unconditionally
and to cache/redistribute.

## Tests

- `test_schema_json_lists_every_registered_action` — assert the exported
  `actions` keys equal `WorkflowActions.names` (drift guard: the export
  can't omit or invent an action).
- `test_schema_json_required_keys_match_registry` — per action, exported
  `required` equals `WorkflowActions.required_keys(name)`.
- `test_schema_json_includes_plan_verbs_and_operators` — assert the
  `extract_plan_verbs`, `normalize_plan_verbs`, and
  `when_context_operators` keys are present and non-empty.
- `test_schema_json_is_valid_json_and_exits_zero` — parse stdout, assert
  exit 0, assert no Chrome/network side effects.
- `test_every_action_has_a_summary` — locks the new `summary` field so a
  future action can't be added without one.
