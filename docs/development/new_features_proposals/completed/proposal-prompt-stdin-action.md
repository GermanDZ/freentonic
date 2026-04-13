# Proposal — `prompt_stdin_and_fill` workflow action

**Status:** implemented. Produced by a providers-agent working on a
provider that requires SMS OTP during login.

**Consuming provider:** any provider that needs to complete an SMS OTP
step on first login or on sessions that request movement history
older than ~30 days.

## Why this belongs in the framework

Some banks' login flows include an interactive SMS OTP challenge. The
current `BrowserWorkflowRunner` action set has no way to express
"block the pipeline, read one line from the user's terminal, write
it into a DOM input, click submit, continue". Specifically:

- `fill` takes a static value or `secret(NAME)` — both are resolved
  from persistent sources. Single-use codes must not become
  persistent secrets.
- `secret(NAME)` is cached after first resolution for the duration
  of the run. Re-resolving the same name on every run to re-prompt
  would abuse the cache semantics and surprise anyone debugging a
  workflow.
- No existing action reads from stdin at all. The CLI's
  `Secrets::Cli` backend prompts for secret *values*, but that's
  invoked from `SecretResolver`, not from the workflow runner, and
  its output goes to the backend store.

Composing existing actions does not emulate blocking-read +
single-write-to-selector. A new action is the smallest change that
unblocks the provider.

## Declarative shape

```yaml
phases:
  login:
    - action: prompt_stdin_and_fill
      selector: "input[name='otp']"
      prompt: "Enter the SMS code your bank sent you: "
      timeout: 300           # seconds; required, no default
      submit_selector: "button[type='submit']"  # optional
      mask: false            # optional; if true, use IO.console.getpass
```

Runtime behavior:

1. Print `prompt` to **stderr** (stdout is reserved for structured
   output from stages).
2. Block on stdin up to `timeout` seconds. On timeout, raise
   `Freentonic::UserError` with "prompt_stdin_and_fill: timed out
   waiting for user input on #{selector}".
3. If `$stdin.tty?` is false, raise `UserError` immediately without
   blocking. Rationale: we don't want a piped/CI context to silently
   consume an unrelated line from stdin.
4. If `mask: true`, use `IO.console.getpass(prompt)` from the
   `io/console` stdlib. Otherwise plain `$stdin.gets.chomp`.
5. Reject empty input (after chomp) with `UserError`.
6. Write the value into `selector` via the same `runtime_call('fill',
   selector, value)` path the existing `fill` action uses — this is
   how the JS injection invariant is preserved (value goes through
   `JSON.generate` before injection).
7. If `submit_selector` is set, dispatch a `click` against it via
   `runtime_call` too.
8. Log `[yml] prompt_stdin_and_fill: filled <selector>` to stdout.
   Do **not** log the captured value. Do **not** log the length of
   the captured value.

## Non-goals

- No secret persistence. The captured value lives in a local variable
  in the helper method and goes out of scope as soon as the action
  returns. It never touches `@secret_resolver`, `@context`, or any
  stage dump.
- No re-prompting on typos. If the user mistypes, the pipeline fails
  with a clear error and the user re-runs. Building retry loops into
  this action adds complexity the providers don't need.
- No multi-field prompts. One action = one value = one selector. If a
  provider needs two codes, chain two actions.
- No integration with the secret backends. This is not a secret.

## Security considerations (for the framework-agent to re-validate)

1. **Injection surface.** The captured value is attacker-controlled
   (the "user" could paste anything, including JS). The only safe way
   to get it into the DOM is via the existing `runtime_call` helpers,
   which `JSON.generate` every argument before interpolation. Do not
   build the `Runtime.evaluate` expression by string-interpolating the
   value — that's the single highest-value invariant to preserve
   (AGENTS.md invariant #2).
2. **Secrets hygiene.** The captured value must never appear in
   stdout, stderr, or any `[yml] ...` log line. The existing `fill`
   action currently logs the selector + value-length; **this new
   action must not log the length either** (even length leaks bits
   about OTP format and makes debugging-vs-security trade-offs
   ambiguous — just don't).
3. **Timeout enforcement.** A missing `timeout:` key must raise
   `UserError` at schema validation time, not at runtime. Without a
   timeout, a stalled pipeline holds a logged-in Chrome session open
   indefinitely, which is a security regression.
4. **Non-TTY rejection.** Reading from a pipe could silently consume
   the next line of a shell script, which is both a security and a
   DX bug. `$stdin.tty?` must be checked at the start of the action,
   before any `gets`.
5. **No eval, no const_get, no new YAML dynamism.** Preserves every
   invariant in `SECURITY.md`.
6. **No runtime dependencies added.** `timeout` and `io/console` are
   stdlib on Ruby 3.4+.

## Scope of change (estimated)

- **Modified:** `lib/freentonic/browser_workflow_runner.rb` — add one
  `when "prompt_stdin_and_fill"` branch and one private helper method.
  Expect ~40 lines including comments.
- **Modified:** `lib/freentonic/workflow_schema.rb` — add shape
  validation in `validate!`: required keys (`selector`, `prompt`,
  `timeout`), optional keys (`submit_selector`, `mask`), types.
- **Modified:** `test/browser_workflow_runner_test.rb` — new test
  cases listed in "Test plan" below.
- **Modified:** `test/workflow_schema_client_test.rb` — new negative
  test for missing `timeout:`.
- **Modified:** `README.md` — add the action to whatever action
  reference table exists (or start one).
- **Modified:** `SECURITY.md` — add a line under "sensitive inputs"
  noting that `prompt_stdin_and_fill` handles single-use values that
  are never persisted.
- **Modified:** `examples/example_bank.yml` — add a commented example
  of an optional OTP step.

No new files. No new dependencies.

## Test plan

- `test_prompt_stdin_and_fill_happy_path` — stdin stubbed to
  `"123456\n"`, assert the `fill` runtime call was dispatched with
  `"123456"` (JSON-encoded).
- `test_prompt_stdin_and_fill_timeout` — stdin stubbed to block
  forever, assert `UserError` raised after `timeout`, assert Chrome
  session was not left in a weird state (no dangling
  `Runtime.evaluate` calls after the raise).
- `test_prompt_stdin_and_fill_rejects_non_tty` — `$stdin.tty?` stubbed
  false, assert immediate `UserError` without any `gets` call.
- `test_prompt_stdin_and_fill_rejects_empty_input` — stdin stubbed to
  `"\n"`, assert `UserError`.
- `test_prompt_stdin_and_fill_escapes_payload` — stdin stubbed to
  `%q{123"; alert(1)}`, assert the runtime expression contains the
  JSON-encoded form (`"123\\\"; alert(1)"`), not the raw string.
- `test_prompt_stdin_and_fill_does_not_log_value` — capture stdout
  and stderr, assert neither contains the captured value nor its
  length.
- `test_prompt_stdin_and_fill_clicks_submit_when_provided` — verify
  the `submit_selector` dispatches a second `runtime_call('click',
  submit_selector)`.
- `test_workflow_schema_rejects_prompt_stdin_and_fill_without_timeout`
  — schema-level validation.

All tests use the existing `FakeSession` pattern from
`test/browser_workflow_runner_test.rb`. Stdin is stubbed via a
`StringIO` assigned to a runner-level `@stdin` ivar (introduce this
if it doesn't exist yet — the runner currently hard-codes `$stdin`
in no place, so threading it through as an injectable dependency is
a prerequisite cleanup).

## Open questions for the framework-agent

1. **Injectable stdin.** `BrowserWorkflowRunner` currently has no
   `@stdin`. Adding one is a small refactor but touches the
   constructor signature. Should we introduce it as a named keyword
   with a `$stdin` default, or carry it on `@context[:stdin]`? The
   existing `@context[:stdout]`/`@context[:stderr]` pattern argues
   for the latter.
2. **Skip-if-not-present variant.** Some banks may skip the OTP
   challenge entirely on devices the bank has seen before. The
   provider would then want a way to say "fill this OTP if the input
   is present; otherwise continue". Two possibilities:
   - Add an `if_present: true` flag to `prompt_stdin_and_fill`.
   - Require the provider to wrap this in a `wait_for_first_of`
     that can branch the pipeline.
   The second is more composable but doesn't exist yet. Decide with
   the user before implementing.
3. **Should we log anything at all?** The minimalist position is "log
   the action name and nothing else". The pragmatic position is "log
   the selector so operators can see where the prompt fired". Both
   are defensible. Pick one, document it, don't change it later.

## Handing back

When implementing this, the framework-agent should:

- Read this proposal end-to-end.
- Read the consuming provider's investigation doc for context
  (explains *why* the OTP is needed and what happens downstream
  once it's filled).
- Validate the implementation against the consuming provider YAML
  draft via `--from-raw` (with a hand-crafted fixture, since no
  live login is possible in CI).
- Run both `bundle exec rake test` in `freentonic` and
  `bundle exec rake test` in `freentonic-providers` before considering
  the change done.
- Not open the Issue or PR directly. Produce them as markdown drafts
  in the chat output, let the user review and file them.
