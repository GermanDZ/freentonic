# Proposal — Interactive debug session actions

**Status:** draft. Builds on top of `record_requests` / `dump_requests`
(implemented in `proposal-debug-request-capture.md`) and
`prompt_stdin_and_fill` (implemented in `proposal-prompt-stdin-action.md`).
All three predecessors are merged. This proposal can be implemented
independently.

**Motivation:** creating a new freentonic provider today looks like this:

1. Write a login workflow from the bank's HTML (or guess at it).
2. Run it. It breaks halfway through because the bank changed a
   selector, added an interstitial, or redirected to an unexpected URL.
3. Open Chrome DevTools in parallel, click around manually, take notes
   on what happened, tweak the YAML, re-run.
4. Repeat 20–50 times until the login flow is stable.

The bottleneck is **step 3**: the human must mentally diff what the
workflow did versus what they did manually, then translate that diff
into YAML. Freentonic already has the tools to observe what happens
(CDP events, `record_requests`), but it has no way to say "stop here,
let me drive for a bit, and tell me what you saw". This proposal adds
that missing link.

**Consuming use case:** every new provider. Past investigations
stalled repeatedly because the agent couldn't observe what happened
after a manual click. Another investigation required manually navigating
to a "movements" page and then wondering which API endpoint fired.
Both would have been solved by `pause` + `record_requests` + `dump_requests`.

## Why this belongs in the framework

- The investigation loop (write YAML → fail → inspect manually → fix)
  is the single slowest part of provider authoring. Framework-level
  tooling for that loop benefits every provider, not just one.
- The building blocks already exist: `prompt_stdin_and_fill` proved
  that blocking on stdin is safe and testable; `record_requests` proved
  that CDP event collection works without JS injection.
- Keeping investigation inside the workflow YAML means the same file
  that becomes the production provider also serves as the debug harness.
  No out-of-band scripts or browser extensions.

## Scope — incremental, three tiers

This proposal defines three tiers, each independently shippable. Start
with Tier 1; only move to Tier 2 if real usage shows the need.

---

### Tier 1: `pause` action

The simplest possible interactive step: stop the workflow, print a
message, wait for the user to press Enter, continue.

```yaml
phases:
  investigate:
    - action: record_requests
      url_matches: ["bank.example/api/"]
      include_response_body: true

    - action: navigate
      url: https://bank.example/login

    - action: pause
      message: "Navigate manually to the accounts page, then press Enter."
      timeout: 600

    - action: dump_requests
      path: "/tmp/manual_capture.ndjson"
```

#### Options

| Option    | Type      | Required | Default | Description |
| --------- | --------- | -------- | ------- | ----------- |
| `message` | `string`  | **yes**  | —       | Text shown to the user on stderr. Should describe what they need to do. |
| `timeout` | `integer` | **yes**  | —       | Maximum seconds to wait. Must be >= 1. Enforced at schema load time, same as `prompt_stdin_and_fill`. |

#### Semantics

- Print `message` to stderr (same convention as `prompt_stdin_and_fill`).
- Block on `$stdin.gets` with the given timeout.
- Requires a TTY — refuses non-tty stdin, same as `prompt_stdin_and_fill`.
- Does **not** capture or store the user's input (they just press Enter).
  The value is discarded.
- Logs `[yml] pause: resumed after Ns` to stdout. Does not log the
  message content (it may contain investigation-specific details the user
  does not want in structured logs).
- While paused, `record_requests` continues to capture traffic because
  CDP Network events keep arriving on the WebSocket regardless of
  whether the workflow is advancing. This is the key composition: pause
  lets the human drive the browser while the framework records
  everything.

#### Implementation

This is essentially `prompt_stdin_and_fill` without the fill. The
implementation is ~15 lines:

```ruby
when "pause"
  pause_for_user(step)
```

```ruby
def pause_for_user(step)
  message = step.fetch("message")
  timeout_seconds = Integer(step.fetch("timeout"))

  unless @stdin.respond_to?(:tty?) && @stdin.tty?
    raise UserError, "pause: refusing to block on non-tty stdin"
  end

  @stderr.print(message)
  @stderr.print(" [press Enter to continue] ")
  @stderr.flush if @stderr.respond_to?(:flush)

  started = Time.now
  begin
    Timeout.timeout(timeout_seconds) { @stdin.gets }
  rescue Timeout::Error
    raise UserError, "pause: timed out after #{timeout_seconds}s"
  end

  elapsed = (Time.now - started).round(1)
  @stdout.puts "    [yml] pause: resumed after #{elapsed}s"
end
```

#### Schema validation

- `message` must be a non-empty string.
- `timeout` must be a positive integer.
- Same pattern as `prompt_stdin_and_fill` validation.

#### Tests

- `test_pause_happy_path` — stdin stubbed to `"\n"`, assert log shows
  "pause: resumed", assert no Runtime.evaluate calls.
- `test_pause_timeout` — stdin blocks forever, assert UserError.
- `test_pause_rejects_non_tty` — stdin.tty? false, assert UserError.
- `test_pause_does_not_log_message` — assert stdout does not contain
  the message text.

---

### Tier 2: `capture_url` action

Captures the current `window.location.href` into the workflow context.
Simple utility that's useful both during investigation (log where you
ended up) and in production (conditional logic based on which page the
bank redirected to).

```yaml
- action: capture_url
  as: current_page

# Then use it in a when_context gate or just inspect it in the dump:
- action: note
  message: "Landed on: {current_page}"
```

#### Options

| Option | Type     | Required | Description |
| ------ | -------- | -------- | ----------- |
| `as`   | `string` | **yes**  | Context key to store the URL under. |

#### Semantics

- Evaluates `window.location.href` via `Runtime.evaluate`.
- Stores the result in `@context[as]`.
- Logs `[yml] capture_url: → ctx.<as>` (does not log the URL itself —
  it may contain session tokens in query params).

#### Implementation

~10 lines. Uses the existing `current_url_value` private method.

```ruby
when "capture_url"
  as_key = step.fetch("as")
  url = current_url_value
  @context[as_key.to_s] = url
  @stdout.puts "    [yml] capture_url: → ctx.#{as_key}"
```

#### Tests

- `test_capture_url_stores_in_context` — assert `context["current_page"]`
  is set.
- `test_capture_url_does_not_log_url` — assert stdout does not contain
  the URL.

---

### Tier 3: `record_dom_events` action (deferred)

Injects a JavaScript event listener that records user interactions
(click, input, change, submit, navigation) as structured entries in a
log. Combined with `pause`, this would let the framework observe
exactly what the user did manually — producing a draft action sequence
that can be translated into YAML.

```yaml
- action: record_dom_events
  events: [click, input, submit]
  max_entries: 500

- action: pause
  message: "Click through the login flow, then press Enter."
  timeout: 600

- action: dump_dom_events
  path: "/tmp/user_actions.ndjson"
```

Each logged entry would look like:

```json
{
  "timestamp": "2026-04-12T14:32:01.123Z",
  "event": "click",
  "target": {
    "tag": "BUTTON",
    "id": "submit-btn",
    "classes": ["primary", "large"],
    "text": "Iniciar sesión",
    "selector_hint": "button#submit-btn.primary"
  },
  "url": "https://bank.example/login",
  "value": null
}
```

For `input` events, `value` would contain the input's new value (or
`"[redacted]"` if the input is `type="password"`).

#### Why defer this

- **JS injection surface.** This is the first action that would inject
  non-trivial JavaScript into the page. The listener must be carefully
  scoped to avoid interfering with the bank's own event handlers (use
  capture phase, passive listeners, and avoid `preventDefault`).
- **Selector generation is hard.** The `selector_hint` field requires
  a heuristic CSS selector generator (prefer `#id`, fall back to
  `.class`, fall back to `nth-child`). Getting this wrong produces
  hints that don't actually work in the YAML.
- **Shadow DOM complication.** Events inside shadow roots bubble
  differently. The listener needs to handle `event.composedPath()` to
  produce correct selectors.
- **No concrete consumer yet.** Tier 1 (`pause`) + existing
  `record_requests` covers the immediate investigation needs. DOM event
  recording becomes valuable when provider authoring moves toward
  "record and replay" — that's a workflow shift, not just a feature
  addition.
- **Privacy.** Capturing every keystroke touches PII directly. The
  password masking heuristic (`type="password"` → redact) is necessary
  but not sufficient — some banks use custom PIN pads, virtual
  keyboards, or plain `type="text"` for sensitive fields. Getting the
  redaction wrong is a security regression.

#### Revisit when

- Two or more provider authors report that `pause` + `record_requests`
  is not enough — they specifically need to see which DOM elements the
  user clicked, not just which network requests fired.
- Or when an agent-driven provider creation workflow exists where the
  agent watches a human session and auto-generates YAML — at that point
  DOM events become the primary input, not a debugging aid.

---

## Composition patterns

The real value of these actions is how they compose with each other
and with existing actions. Here are the key patterns:

### Pattern 1: Manual exploration with network capture

The "I don't know what API calls this page makes" investigation:

```yaml
phases:
  investigate:
    - action: record_requests
      url_matches: ["bank.example/"]
      include_response_body: true
      max_entries: 1000

    - action: pause
      message: |
        Browser is ready. Navigate to the page you want to investigate.
        Click around, load accounts, view movements — whatever you need.
        When done, press Enter.
      timeout: 600

    - action: dump_requests
      path: "/tmp/exploration.ndjson"

    - action: capture_url
      as: final_url

    - action: note
      message: "Done. Check /tmp/exploration.ndjson for captured traffic."
```

### Pattern 2: Assisted login debugging

The "login breaks at step 3 and I need to see what happens next":

```yaml
phases:
  login:
    - action: navigate
      url: https://bank.example/login
    - action: fill
      selector: "#user"
      value: "secret(USER_ID)"
    - action: fill
      selector: "#password"
      value: "secret(USER_PASSWORD)"
    - action: click
      selector: "#submit"

    # Login submitted — but we don't know where it redirects.
    # Pause and let the user observe, while recording everything.
    - action: record_requests
      url_matches: ["bank.example/"]
      include_response_body: true

    - action: pause
      message: "Login submitted. Observe the redirect, then press Enter."
      timeout: 120

    - action: capture_url
      as: post_login_url

    - action: dump_requests
      path: "/tmp/post_login.ndjson"

    - action: note
      message: "Post-login URL: {post_login_url}"
```

### Pattern 3: Multi-phase investigation

Record separate captures for different pages:

```yaml
phases:
  investigate_accounts:
    - action: record_requests
      url_matches: ["bank.example/api/"]
      include_response_body: true

    - action: pause
      message: "Navigate to the accounts list, then press Enter."
      timeout: 300

    - action: dump_requests
      path: "/tmp/accounts_traffic.ndjson"
      reset: true

  investigate_movements:
    - action: pause
      message: "Navigate to a specific account's movements, then press Enter."
      timeout: 300

    - action: dump_requests
      path: "/tmp/movements_traffic.ndjson"
      reset: true
```

---

## Security considerations

### `pause`

1. **No new injection surface.** The action does not inject JS, does not
   evaluate expressions, does not touch the DOM. It just blocks on stdin.
2. **Timeout is mandatory.** Same rationale as `prompt_stdin_and_fill`:
   a missing timeout holds a logged-in session open indefinitely.
3. **TTY required.** Same check as `prompt_stdin_and_fill`.
4. **Message not logged to stdout.** The message may contain
   investigation-specific details. It goes to stderr only (same as
   `prompt_stdin_and_fill`'s prompt).

### `capture_url`

1. **URL may contain tokens.** Some banks embed session tokens in query
   parameters. The URL is stored in `@context` (visible in stage dumps
   if the dump code changes). The action does not log the URL to stdout.
2. **No JS injection.** Uses `Runtime.evaluate` with a hardcoded
   expression (`window.location.href`), not user-controlled input.

### `record_dom_events` (Tier 3, deferred)

See the "Why defer this" section above. The JS injection surface and
PII capture concerns are the primary reasons this is not in scope.

---

## Scope of change

### Tier 1 (`pause`)

- **Modified:** `lib/freentonic/browser_workflow_runner.rb` — add
  `when "pause"` branch + `pause_for_user` helper. ~15 lines.
- **Modified:** `lib/freentonic/workflow_schema.rb` — validate `message`
  and `timeout` for `pause`. ~10 lines.
- **Modified:** `test/browser_workflow_runner_test.rb` — 4 new tests.
- **Modified:** `test/workflow_schema_client_test.rb` — 2 new tests.
- **New file:** `docs/workflow-action-pause.md` — action reference.
- **Modified:** `docs/workflow-actions.md` — add to index.

### Tier 2 (`capture_url`)

- **Modified:** `lib/freentonic/browser_workflow_runner.rb` — add
  `when "capture_url"` branch. ~5 lines.
- **Modified:** `lib/freentonic/workflow_schema.rb` — validate `as`. ~5 lines.
- **Modified:** `test/browser_workflow_runner_test.rb` — 2 new tests.
- **Modified:** `test/workflow_schema_client_test.rb` — 1 new test.
- **New file:** `docs/workflow-action-capture-url.md` — action reference.
- **Modified:** `docs/workflow-actions.md` — add to index.

No new runtime dependencies in any tier. Everything is CDP events +
stdlib.

---

## Test plan

### Tier 1

- `test_pause_happy_path` — stdin stubbed to `"\n"`, assert log shows
  "pause: resumed after", assert no Runtime.evaluate calls dispatched.
- `test_pause_timeout` — stdin blocks, assert UserError after timeout.
- `test_pause_rejects_non_tty` — stdin.tty? false, assert UserError
  without blocking.
- `test_pause_does_not_log_message` — capture stdout, assert it does
  not contain the message text.
- `test_workflow_schema_rejects_pause_without_message` — schema-level.
- `test_workflow_schema_rejects_pause_without_timeout` — schema-level.

### Tier 2

- `test_capture_url_stores_in_context` — assert `context["current_page"]`
  is populated.
- `test_capture_url_does_not_log_url` — assert stdout does not contain
  the URL value.
- `test_workflow_schema_rejects_capture_url_without_as` — schema-level.

All tests use the existing `FakeSession` / `PromptSchemaDouble` pattern.
No live Chrome.

---

## Open questions for the framework-agent

1. **Should `pause` drain CDP events while waiting?** Currently
   `record_requests` drains events synchronously at each `execute_step`
   call. During a `pause`, no steps execute, so events accumulate in the
   WebSocket buffer. They'll be drained on the next step after the pause
   resumes. This is fine for short pauses but a very long pause (~10
   minutes) might overflow the WebSocket buffer. Options:
   - Accept it — the buffer is memory-backed and browsers handle long
     idle periods fine.
   - Spawn a drain thread for the duration of the pause only.
   - Periodically drain in the pause loop (add a small `select` loop
     that reads stdin while also draining events).
   Lean toward "accept it" for Tier 1 — optimize only if real usage
   shows buffer issues.

2. **Should `capture_url` resolve `{context_key}` patterns in the `as`
   value?** Probably not — the `as` key is a plain string, same as
   `capture_header` and `capture_cookie_header`. Keep it simple.

3. **Should `pause` accept a `capture_url: true` shorthand?** It's
   tempting to combine them, but keeping them as separate composable
   actions is more consistent with the framework's design. Two YAML
   lines is not a real cost.

4. **Naming: `pause` vs `wait_for_user` vs `manual_step`.** `pause` is
   the shortest and most intuitive. `wait_for_user` is more descriptive
   but longer. `manual_step` implies the user *must* do something
   specific, which isn't always the case (sometimes you just want to
   observe). Lean toward `pause`.

## Handing back

When implementing Tier 1, the framework-agent should:

- Read this proposal end-to-end.
- Implement `pause` following the `prompt_stdin_and_fill` pattern
  exactly — same stdin/tty checks, same timeout enforcement, same
  logging conventions.
- Implement `capture_url` as a trivial wrapper around the existing
  `current_url_value` method.
- Add both to `docs/workflow-actions.md` and create their dedicated doc
  files.
- Run `bundle exec rake test` before considering the change done.
- Not open the Issue or PR directly. Produce them as markdown drafts
  in the chat output, let the user review and file them.
