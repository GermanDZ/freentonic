# AGENTS.md — freentonic

Instructions for autonomous coding agents (Claude Code, Cursor, Aider,
etc.) working in this repository. **If you are a human contributor,
start with [`README.md`](README.md) and
[`docs/writing-plugins.md`](docs/writing-plugins.md) — those are the
technical references this file delegates to.**

This file is the **framework-side** counterpart to
[`freentonic-providers/AGENTS.md`](https://github.com/GermanDZ/freentonic-providers/blob/main/AGENTS.md).
Together they cover the full workflow: the providers-agent discovers
a missing capability, produces Issue + PR drafts, and a framework-
agent (you, when invoked here) implements them.

## Mission

You are working inside the **framework**, not a provider. In this
repo you will almost always be doing one of:

1. **Implementing a capability that a providers-agent proposed** — a
   new workflow action, a new api_client DSL macro, a new exporter,
   a new secret backend, a new pipeline stage, or a schema extension.
2. **Fixing a framework-level bug** surfaced by a provider or by the
   test suite.
3. **Refactoring** a subsystem without changing behavior.
4. **Updating docs** (README, SECURITY.md, writing-plugins.md).

You are **not** here to build or debug any specific provider. If the
user asks you to add support for "a new bank", redirect them: that
work belongs in `freentonic-providers`, which has its own AGENTS.md
covering the HAR-capture-driven authoring loop. You only touch this
repo if the provider work has revealed something the framework
itself needs.

## Before you start — questions to ask the user

Ask these up front and stop to wait for answers. Skip any the user
already answered in the conversation.

### Is this actually a framework change?

1. **What exactly are you trying to enable?** In one sentence. If
   the user can't give you one sentence, the proposal isn't ready —
   help them narrow it, don't start coding.
2. **Is there an existing Issue + PR draft from a providers-agent?**
   If yes, read it end-to-end before doing anything else. It should
   already include: motivation, declarative YAML shape, alternatives
   considered, security considerations, and estimated scope. If any
   of those are missing, fill the gaps with the user before writing
   code.
3. **Could this live in a plugin instead?** Three of freentonic's
   four extension points (exporters, secret backends, normalizers)
   load via `-r ./my_plugin.rb` and need no framework change at all.
   If the user's need is "I want to POST results to Slack", that's
   a plugin, not a core change. Read
   [`docs/writing-plugins.md`](docs/writing-plugins.md) and push
   back on the proposal if a plugin would work.
4. **Which existing providers would benefit?** Name at least one
   real provider in `freentonic-providers` that would use the new
   capability. If the answer is "none, but it might be useful
   someday", the proposal is speculative — either find a concrete
   consumer or defer.
5. **What's the smallest shape that solves the user's problem?**
   Core framework changes are sticky — removing a YAML key or a
   workflow action breaks every provider that relied on it. Favor
   adding **one well-defined thing** over extending an existing
   feature with flags.

### Red flags — stop and ask

- The user wants to add a runtime gem dependency. **Freentonic is
  zero-runtime-deps by design** (see the gemspec). Even small deps
  drag in a supply chain. Flag and discuss alternatives before
  writing code.
- The user wants to loosen `YAML.safe_load` (permit classes,
  enable aliases, etc.). This is a security boundary — flag and do
  not proceed without explicit security review.
- The user wants to add a `workflow_schema.rb` change that makes
  YAML more dynamic (string interpolation into constants, `eval`
  into step values, …). Same as above.
- The user wants to bump `required_ruby_version` or drop support
  for a Ruby version. This affects downstream users — flag.
- The user wants to change the shape of the payload passed between
  stages (e.g. mutate `context[:raw]` semantics, rename
  `context[:normalized]`). This is a breaking change for every
  provider that uses `--from-raw` / `--from-normalized`. Flag and
  discuss migration.

## Architecture map

Before you edit anything, know which subsystem you're in. Each
subsystem has a different review posture.

| Subsystem           | Files                                                 | What lives here                                                    |
| ------------------- | ----------------------------------------------------- | ------------------------------------------------------------------ |
| CDP transport       | `lib/freentonic/chrome_cdp.rb`                        | Chrome lifecycle, WebSocket, cookie RFC helpers.                   |
| Workflow actions    | `lib/freentonic/browser_workflow_runner.rb`           | The declarative `action:` dispatch table + per-action primitives.  |
| API client DSL      | `lib/freentonic/api_client.rb`                        | `base_url`, `auth_header`, `define_get/post`, pagination helpers.  |
| Workflow schema     | `lib/freentonic/workflow_schema.rb`                   | YAML → runtime binding + validation + `api_client.ext` loader.     |
| Source              | `lib/freentonic/source.rb`                            | `credentials:` validation + mapping from captured context.         |
| Secret resolver     | `lib/freentonic/secret_resolver.rb`                   | `secret(NAME)` recursive resolution with caching.                  |
| Pipeline stages     | `lib/freentonic/stages/`                              | `Connect`, `Elevate`, `Extract`, `Normalize`, `Export` stage drivers. |
| Engine              | `lib/freentonic/engine.rb`                            | Stage orchestration, stage ordering, serialization hooks.          |
| CLI                 | `lib/freentonic/cli.rb`, `bin/freentonic`             | OptionParser, `-r` pre-processing, exporter/secret wiring.         |
| Exporter plugins    | `lib/freentonic/exporters/`                           | `Base`, `Json`, `Jsonl`, `Csv`, `Http` + registry.                 |
| Secret backend plugins | `lib/freentonic/secrets/`                          | `Store`, `Cli`, `MacosKeychain`, `PlainFile` + registry.           |
| Normalizer plugins  | `lib/freentonic/normalizers/`                         | `Base`, `Passthrough`. Real normalizers live in providers.         |

Two maps to keep in your head:

- **Plugin extension points (3)** — exporters, secret backends,
  normalizers. These load via `-r` or relative path. **Adding a new
  one in this repo only makes sense if it ships by default** (useful
  to most users, covered by the invariant contract, tested in CI).
  Everything else is a user's own file outside this repo.
- **Core extension points (4)** — workflow actions, api_client DSL
  macros, credential capture steps, pipeline stages, schema keys.
  These **must** be in this repo because they're consumed by
  declarative YAML.

## Invariants — non-negotiable

These are the rules the framework guarantees to every provider,
every plugin author, and every security reviewer. If your change
breaks one of them, it is a security bug and should not merge.

1. **`YAML.safe_load(permitted_classes: [], aliases: false)`.** The
   call site is `WorkflowSchema.load`. You may not pass additional
   `permitted_classes`. You may not enable aliases. You may not
   introduce a second code path that loads YAML any other way.
2. **Every string injected into Chrome via `Runtime.evaluate`
   serializes its arguments through `JSON.generate`.** The patterns
   are `runtime_call`, `runtime_deep_call`, and `runtime_shadow_eval`
   in `browser_workflow_runner.rb`. If you add a new workflow action
   that injects JS, use one of those helpers — do not build your own
   string-interpolated expression.
3. **`Process.spawn` is always called with the array form.** No
   shell strings, no `exec "cmd #{var}"`. The one site that spawns
   (`chrome_cdp.rb#launch_chrome`) already enforces this; any new
   subprocess call must too.
4. **`api_client.ext` requires explicit `file:` and `module:`
   keys.** The module is resolved via
   `const_get(name, false)` walks. No string interpolation, no
   `Object.const_get("Prefix::#{key}")` patterns. This is in
   `WorkflowSchema#load_client_ext` — don't replace it with a
   shortcut.
5. **Zero runtime gem dependencies.** The gemspec has no
   `add_dependency` calls. Dev-only gems go in the Gemfile under
   the `:development, :test` group. Ruby 3.4+ default gems (base64,
   csv) are in the Gemfile too but must NOT appear in the gemspec.
6. **Plugin registries are authoritative.** Don't hard-code plugin
   names anywhere in the framework core. The CLI's `--export`,
   `--secrets`, `--only-stage` flags read from `Exporters.registered`,
   `Secrets.registered`, and the `STAGE_ORDER` constant respectively.
   A new plugin must register; the framework must not special-case it.
7. **No mutation of frozen constants.** If you add a registry or
   constant, follow the existing shape (`@registry = {}` module
   instance var, accessed via `class << self` methods).
8. **Stage context keys are a public contract.** `context[:source]`,
   `context[:credentials]`, `context[:raw]`, `context[:normalized]`,
   `context[:exporters]`, `context[:secret_resolver]`,
   `context[:stdout]`, `context[:stderr]` — renaming or removing
   any of these is a breaking change. New keys are fine as long as
   they don't collide.
9. **CLI flag names are a public contract.** `--workflow`,
   `--from-raw`, `--export NAME`, `--export-path`, `--secrets`,
   etc. Removing or renaming any of these breaks user shell
   scripts. Adding new flags is fine; deprecating old ones needs a
   release note.
10. **Tests run without network access and without Chrome.** Every
    test in `test/` stubs network I/O and CDP. If you add a test
    that requires a live browser or a real HTTP server, you're
    doing it wrong — see `test/exporters_test.rb`'s
    `with_net_http_new` helper for the stdlib-only stub pattern.

## Tools available in this repo

```sh
# Install dev dependencies (Ruby 3.4+ needs base64/csv declared).
bundle install

# Run the full test suite.
bundle exec rake test

# Run one test file directly (no Bundler, no rake — fastest loop).
ruby -Ilib -Itest test/browser_workflow_runner_test.rb

# Syntax-check every library file in one shot.
ruby -Ilib -e 'Dir["lib/**/*.rb"].each { |f| require File.expand_path(f) }'

# Load and validate a provider workflow YAML (useful when validating
# that a schema change didn't break existing providers).
ruby -Ilib -rfreentonic -e \
  'p Freentonic::WorkflowSchema.load(ARGV[0]).config' \
  ../freentonic-providers/ing/workflow.yml

# Smoke-test the CLI end-to-end with a captured raw payload (no bank).
ruby -Ilib bin/freentonic \
  --workflow ../freentonic-providers/ing/workflow.yml \
  --from-raw /tmp/ing_raw.json \
  --export json --export-path /tmp/out.json
```

## How to add each kind of capability

Every recipe below follows the same shape: implement → register
(where applicable) → test → doc. Skip any step and the change is
incomplete.

### 1. New workflow action (`action: <name>` in YAML)

This is the most common framework change requested by providers-
agents. A workflow action is a new branch in
`BrowserWorkflowRunner#execute_step`.

**Implementation:**
- Open `lib/freentonic/browser_workflow_runner.rb`.
- Find the `case action` block in `#execute_step`.
- Add a new `when "<name>"` branch. Extract step parameters with
  `step.fetch("key")` (fail loud) or `step.fetch("key", default)`.
- Put the actual work in a private method named after the action
  (`def drag_slider(selector, from:, to:)`, etc.).
- If the private method injects JavaScript, **route it through
  `runtime_call`, `runtime_deep_call`, or `runtime_shadow_eval`.**
  Never build a `Runtime.evaluate` expression by string-
  interpolating a step parameter — that's a JS injection bug.
- If the step resolves a value that might be `secret(NAME)`, wrap
  it with `resolved(step.fetch("value"))`. The `resolved` helper
  dispatches through `@secret_resolver`.
- If the step talks to the network, add retries/timeouts with the
  same pattern as `capture_header` (`retries:`, `interval_seconds:`).

**Testing:**
- Open `test/browser_workflow_runner_test.rb`.
- Add a new `test_` method that drives the action against a
  `FakeSession` (already defined in that file). The test must not
  touch a real browser.
- Assert on: the commands the action sent via `session.send_command`,
  any state it wrote to `@context`, and the stdout prefix
  (`[yml] <name>: ...`).
- Verify JS injection points: include a step parameter containing
  a tricky value like `"quote\"`; assert the final expression
  contains the JSON-encoded form, not the raw string.

**Documentation:**
- Update the action table in `README.md` (there isn't one yet — if
  your change is the first one that warrants it, add the table).
- If the action has security-sensitive semantics (reads cookies,
  types secrets, captures response bodies), add a line to the
  relevant section of `SECURITY.md`.
- Consider adding an example to `examples/example_bank.yml`.

### 2. New api_client DSL macro

Used when a provider needs a different auth mechanism, a new
pagination style, a request signing scheme, or a new endpoint shape
(websocket, streaming, multipart).

**Implementation:**
- Open `lib/freentonic/api_client.rb`.
- If it's a new class-level macro (`cursor_pagination`, `hmac_sign`,
  …), add it inside the `class << self` block alongside `credentials`,
  `batch_keys`, `date_format`, etc. Follow the existing pattern:
  capture the config in an instance-level method via `define_method`.
- If it's a new instance helper (like `paginate_by_offset` or
  `paginate_by_cursor`), add it in the `protected` section with
  yard-style docs.
- **Open `lib/freentonic/workflow_schema.rb`** and add a binding in
  `build_api_client_class` so the new macro is reachable from
  YAML. Without this, providers cannot use the new feature.

**Testing:**
- `test/api_client_test.rb` has the pattern: define a minimal
  subclass that exercises the macro, instantiate it, assert on
  behavior. Follow that shape exactly.
- `test/workflow_schema_client_test.rb` tests the YAML binding.
  Add a test that constructs a schema with your new key and
  confirms the built client works end-to-end.

**Documentation:**
- Update the api_client reference in `README.md` (the YAML
  example in the workflow reference section).

### 3. New exporter

Only do this if the exporter should ship by default. Custom
exporters load via `freentonic -r ./my_exporter.rb` and do not need
a framework change.

**Implementation:**
- Create `lib/freentonic/exporters/<name>.rb`.
- Subclass `Freentonic::Exporters::Base`. Implement `#write(payload)`.
- Use `open_output(@options[:path])` for file-or-stdout writing.
- Raise `Freentonic::ExportError` on write failures — the Export
  stage catches these and collects them across multiple exporters.
- Call `register(:name, ClassName)` at the bottom of the file.
- Add `require_relative "freentonic/exporters/<name>"` to
  `lib/freentonic.rb` so the registration happens at load time.
- If the exporter reads CLI flags, add them to `cli.rb`. Follow the
  existing `--export-*` attachment pattern — each `--export NAME`
  creates a new config slot and subsequent `--export-*` flags
  attach to the most recently declared one.

**Testing:**
- Open `test/exporters_test.rb`. Add tests that round-trip the
  sample payload (defined in `sample_payload` helper) through the
  new exporter.
- For network exporters, use the existing `with_net_http_new`
  helper to stub `Net::HTTP.new` — **do not** introduce a real
  HTTP server (that would break invariant 10).
- Cover: happy path, error path (raises `ExportError` with a
  useful message), option validation (missing required option
  raises `UserError`).

**Documentation:**
- Add the exporter to the built-in exporters list in `README.md`.
- If the exporter is a common one worth a worked example, add it
  to `docs/writing-plugins.md` as a reference implementation.

### 4. New secret backend

Same bar as exporters: only ship by default if it covers a common
deployment environment (e.g. Linux Secret Service, Windows
Credential Manager). User-specific backends should stay in `-r`.

**Implementation:**
- Create `lib/freentonic/secrets/<name>.rb`.
- Subclass `Freentonic::Secrets::Store`. Implement `#fetch` and
  `#prompt_and_store`.
- **`#fetch` returns a String or nil.** Never raise for "not
  found" — raise only for environment errors (CLI tool missing,
  permission denied).
- **`#prompt_and_store` returns a non-empty String or raises.**
  Never return nil; if the backend can't prompt (non-interactive),
  raise `UserError` with an actionable message telling the user
  exactly where to add the secret.
- Never log the secret *value*. Secret *names* and *prompts* are
  fine on stdout/stderr; the value must stay in memory.
- Call `register(:name, ClassName)` at the bottom of the file.
- Add `require_relative "freentonic/secrets/<name>"` to
  `lib/freentonic.rb`.
- If the backend should be the OS default, update
  `Secrets.default_name` — but note that changing the OS default
  is a breaking change for anyone who relied on it.

**Testing:**
- `test/secrets_test.rb` has tested patterns for each backend
  style: stdin-driven (`Cli`), file-backed (`PlainFile`), shell-out
  (`MacosKeychain` — but that test is minimal because shelling
  out is hard to stub safely).
- For shell-out backends, stub `Open3.capture3` with a singleton
  method replacement — follow the `with_net_http_new` pattern in
  `test/exporters_test.rb`.

**Documentation:**
- Add the backend to the "Secrets" section of `README.md`.
- Add a worked example (~15 lines) to `SECURITY.md` if the
  backend has interesting security properties worth calling out.

### 5. New pipeline stage

Rare. The five existing stages (Connect → Elevate → Extract →
Normalize → Export) cover every current use case. A new stage is
justified only if you can't make the work fit inside an existing
stage without conflating concerns.

**Implementation:**
- Create `lib/freentonic/stages/<name>.rb`.
- Subclass `Freentonic::Stages::Base`. Implement `#call`, which
  mutates `@context` and returns it.
- Access shared context through the helpers: `stdout`, `stderr`,
  `source`, `schema`. Don't reach for `$stdout` directly.
- Open `lib/freentonic/engine.rb`:
  - Add the stage symbol to `STAGE_ORDER` in the right position.
  - Add the class to `STAGE_CLASSES`.
  - Update `load_serialized_inputs!` and `persist_stage_output`
    if your stage consumes or produces a serializable artifact
    (for `--from-<stage>` / `--dump-<stage>` support).
- Open `lib/freentonic/cli.rb`:
  - Add `<name>` to `STAGE_NAMES`.
  - Add `--dump-<name> PATH` and `--from-<name> PATH` flags if
    your stage has a serializable output.
- Update the `Set` of skipped stages in `stages_to_run` so
  `--from-raw` / `--from-normalized` correctly skips your stage
  when its input is being loaded from disk.

**Testing:**
- Add a new `test/stages_<name>_test.rb`. Drive the stage against
  a hand-crafted context hash.
- Add an end-to-end test to `test/cli_test.rb` that exercises the
  new `--dump-<name>` / `--from-<name>` flags with a fixture
  workflow YAML and a temp directory (like the existing
  `test_from_raw_skips_chrome_and_exports_via_json`).

**Documentation:**
- Update the pipeline table in `README.md`.
- Update the stage control flags list in `README.md`.
- Update the pipeline diagram in `docs/writing-plugins.md` if
  normalizers/exporters would want to distinguish between stages.

### 6. Schema extension (new YAML key)

When you add a new top-level key to workflow YAML or a new nested
key under an existing block (`api_client`, `phases`, …).

**Implementation:**
- Open `lib/freentonic/workflow_schema.rb`.
- Add a reader method that exposes the key: `def <name>; @raw[...] end`.
- **Update `validate!`** to catch malformed values for the new key.
  `validate!` runs at load time, so any shape error surfaces early
  with a clear message. Follow the existing `raise UserError,
  "workflow #{@path} <key> must be a ..."` pattern.
- If the key is optional, define a sensible default in the reader.
  If it's required, make `validate!` fail loud.

**Testing:**
- `test/workflow_schema_client_test.rb` — add a test that
  constructs a schema with the new key and asserts the reader
  returns the expected value.
- Add a negative test: a schema with the key in the wrong shape
  must raise `UserError` from `validate!`.

**Documentation:**
- Update the workflow YAML reference in `README.md`.
- Update `examples/example_bank.yml`.
- If the key has security implications (loads Ruby, injects into
  Chrome, …) add it to `SECURITY.md`'s invariant list.

### 7. New `extract: plan:` verb

The declarative extractor grammar (`lib/freentonic/extract_plan/`) is a
closed verb set — `fetch` / `select` / `for_each` / `yield` (Phase 1);
`let` / `concat` / `dedup_by` + the `when:` gate (Phase 2); `index_by`,
the `note` / `warn` / `abort` message verbs, `skip_when` (for_each only),
and fetch `on_error:` (Ask 5); `lookup` (Ask 6 — dynamic-key map read) —
dispatched by `Interpreter#dispatch` (the `elevate:` phase subclasses it
and adds `await_operator_approval` / `rebind_credential`). A new verb is
justified only when a real provider needs it: Phase 1 took Revolut to zero
Ruby, Phase 2 did the same for Fintonic and Unicaja, and Asks 5–6 cover
ING's remaining orchestration (index-a-list-to-a-map, read-it-back-by-key,
skip-with-warn routing, fatal-fetch guard) — so even ING is now a candidate
for zero extractor Ruby (the `{ruby:, class:}` escape hatch stays as a
general capability). Resist growing `when:` into a
string-predicate expression language, and keep the "no computing verbs"
guardrail: plan verbs filter/dig/index/guard; arithmetic or string surgery
beyond `{templates}` belongs in the normalizer.

**Implementation:**
- Add the verb to `Interpreter#execute`'s dispatch and a
  `do_<verb>` handler in `interpreter.rb`. Keep it pure orchestration
  over declared endpoints + already-fetched data — no `send` off a YAML
  string, no reaching past the endpoint whitelist (that is the invariant
  that makes plans safer than Ruby).
- Add its validator to `WorkflowSchema#validate_plan_step!` (endpoint
  whitelist, binding resolution, required keys) so it is caught at load
  and by `--lint`, not at runtime.
- Reuse existing evaluators where they exist — e.g. a `when:` gate should
  reuse the `when_context` operator set already in `workflow_schema.rb`.

**Testing:**
- `test/extract_plan_test.rb` — interpreter against the `FakeClient`.
- `test/workflow_schema_extract_plan_test.rb` — a negative test that the
  malformed verb raises `UserError` from `validate!`.
- Keep the Revolut parity test green.

**Documentation:**
- Update `docs/extract-plan.md`'s reference tables and the
  when-to-use-a-plan boundary.

## Receiving an Issue + PR draft from a providers-agent

When the user pastes an issue draft that was produced by
freentonic-providers' agent, do this walk:

1. **Read the Issue draft end-to-end.** Don't skim. The declarative
   shape section tells you what the YAML should look like after
   your change lands — that's your contract.
2. **Sanity-check the security considerations section.** If it's
   empty or reads "none", stop — every non-trivial framework
   change has at least one security consideration (JS injection
   surface, secrets leakage, YAML parse behavior). Push the draft
   back to the user or to the providers-agent with a request to
   fill it out.
3. **Check for an alternative lower-risk path.** Can the same
   effect be achieved with an existing action? With a plugin? With
   a small tweak to an existing DSL macro instead of a new one?
   Surface alternatives to the user before implementing.
4. **Pin the consuming provider.** If the issue references "the
   `my_bank` provider needs this", make sure a draft
   `my_bank/workflow.yml` exists — either in-tree in the providers
   repo or attached to the conversation. You will use that as the
   integration-test target in step 6 below.
5. **Implement** following the per-capability recipe above.
6. **Validate against the real consumer.** Load the draft provider
   YAML through `Freentonic::WorkflowSchema.load` and run it
   through the pipeline with `--from-raw` and a hand-crafted
   fixture raw payload. Confirm the provider can actually use the
   new capability end-to-end.
7. **Run the full test suite.** `bundle exec rake test`. If any
   existing test fails, your change broke backwards compatibility
   — do not paper over the failure with a test update. Understand
   it first.
8. **Re-run all providers' tests** against the updated framework.
   From `../freentonic-providers`, run `bundle exec rake test`.
   Zero-failure is a merge prerequisite.
9. **Update SECURITY.md** if you touched anything listed in the
   invariants section of this doc.
10. **Produce the PR** as a commit on a feature branch. Do **not**
    push or open the PR yourself — hand the branch back to the
    user for review.

## Safety rails — never do

- **Never bypass `YAML.safe_load`.** No `YAML.load`, no
  `permitted_classes:` additions, no alias enablement. If you
  genuinely need to permit a class, stop and involve the user for
  a security review.
- **Never string-interpolate user-controlled values into a
  `Runtime.evaluate` expression.** Use `JSON.generate` via the
  existing helpers. This is the single highest-value invariant to
  preserve.
- **Never add a runtime gem dependency.** The gemspec has none,
  and the value of that claim compounds with every release.
- **Never introduce `Object.const_get` off a string you built from
  user input.** The `api_client.ext` loader is the template —
  explicit module name, strict `const_get(name, false)` walk,
  validated at load time.
- **Never remove or rename a public surface** (CLI flag, context
  key, registered plugin name, workflow YAML key) without a
  migration path. The tests won't catch this — providers will,
  silently, in production.
- **Never land a change without running
  `../freentonic-providers` tests against the new framework.** You
  will break a provider you've never heard of. Finding out in CI
  is fine; finding out in a user's `bundle update` is not.
- **Never commit secrets, real bank responses, or PII.** This repo
  is public. Every fixture is hand-crafted and scrubbed.
- **Never skip hooks or disable tests to make a commit go
  through.** If a hook fails, investigate and fix the underlying
  issue.
- **Never open an Issue, open a PR, push to main, or tag a release
  yourself.** All of those are the user's call. Your output is a
  local branch + a summary.

## When to stop and ask

- The proposed change would require a runtime dependency or a
  security invariant relaxation.
- You've implemented the change, tests pass, but the consuming
  provider's draft YAML still doesn't express what the issue said
  it should — something about the proposal was wrong, and you
  don't know which.
- You discovered that the change can only work by also modifying a
  second unrelated subsystem. Scope creep like this usually
  indicates the original proposal was under-specified.
- A test in `test/` failed in a way you don't understand. Don't
  "fix" the test — understand why first.
- You are about to loosen a validation in `WorkflowSchema#validate!`
  because a provider YAML tripped on it. Loosening validation is a
  backwards move; the provider is almost always at fault.
- The user asked you to cut a release or publish to RubyGems. Any
  release-cutting activity is a human-in-the-loop step; prepare
  the changelog entry and hand it back.

## Completion criteria

A framework change is ready to hand back to the user when **all**
of these are true:

- [ ] `bundle exec rake test` is green locally.
- [ ] `../freentonic-providers`' `bundle exec rake test` is green
      against the updated framework.
- [ ] Every subsystem invariant in this doc still holds — you've
      re-read them and checked.
- [ ] SECURITY.md is updated if you touched a security-invariant
      subsystem.
- [ ] README.md is updated if you added a public-facing feature
      (new CLI flag, new workflow action, new exporter, new
      secret backend, new schema key).
- [ ] `docs/writing-plugins.md` is updated if you changed any
      plugin contract (the Base class, the registry API, the `-r`
      loader).
- [ ] `examples/example_bank.yml` is updated if you added a
      workflow YAML key worth showing.
- [ ] The consuming provider (draft YAML) actually loads and runs
      through the new capability — ideally via `--from-raw` with a
      hand-crafted fixture.
- [ ] No runtime gem added to `freentonic.gemspec`.
- [ ] The change is on a feature branch; the user will review and
      decide whether to merge + tag.

## Reference: where to look when you're stuck

| Question                                            | File                                                |
| --------------------------------------------------- | --------------------------------------------------- |
| What does the workflow action dispatch look like?   | `lib/freentonic/browser_workflow_runner.rb`         |
| How do I inject JS safely?                          | `runtime_call` / `runtime_deep_call` / `runtime_shadow_eval` in the same file |
| How is a YAML schema key validated?                 | `lib/freentonic/workflow_schema.rb#validate!`       |
| How does `api_client.ext` stay safe?                | `lib/freentonic/workflow_schema.rb#load_client_ext` |
| Where does the CLI wire exporters together?         | `lib/freentonic/cli.rb#execute` + `#parse`          |
| What's the Stage base contract?                     | `lib/freentonic/stages/base.rb`                     |
| How does the Engine decide which stages to run?     | `lib/freentonic/engine.rb#stages_to_run`            |
| How is a plugin registered at load time?            | Any of `lib/freentonic/exporters/json.rb`, `secrets/cli.rb` (end of file) |
| How do I stub Net::HTTP in a test without gems?     | `test/test_helper.rb#with_net_http_new`             |
| Security invariants + threat model                  | `SECURITY.md`                                       |
| Plugin author contract (base classes)               | `docs/writing-plugins.md`                           |

If you've read the relevant file and still don't know what to do,
stop and ask the user. Framework changes compound — a small mistake
here silently breaks every provider that depends on it.
