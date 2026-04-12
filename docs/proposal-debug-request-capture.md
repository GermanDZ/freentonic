# Proposal — Debug request-capture actions

**Status:** implemented. Produced alongside
`proposal-prompt-stdin-action.md` during a provider investigation
session — but cleanly separable from it.

**Motivation:** during provider authoring, the most valuable artifact
is a HAR capture of the bank's web UI. Today that means asking the
user to open DevTools, enable "Preserve log", click through the
interesting screens, and run "Save all as HAR with content". It
works but is fragile — most HARs end up captured *without* content
(default export mode), which is exactly the bytes the agent needs.
Freentonic already drives Chrome via CDP and already listens on the
`Network` domain for cookie capture. Letting workflow YAML record
requests during a phase would make the framework self-sufficient for
its own investigation loop, without the user touching DevTools.

**Consuming use case:** a provider investigation stalled because both
HARs the user captured were exported without bodies, so the response
field names needed for a pagination loop were still unknown. A
`record_requests` + `dump_requests` action pair would have solved it
in one run.

## Why this belongs in the framework

- Freentonic's `chrome_cdp.rb` already subscribes to `Network.*`
  events (that's how `capture_cookie_header` works). Extending the
  subscription scope is a small change, not a new subsystem.
- Every provider author hits the same "I need a HAR but the one I
  got doesn't have bodies" paper cut. This is a framework-level
  ergonomic fix with concrete consumers and an obvious benefit for
  any future provider with a cursor-paginated or opaque-cursor
  endpoint.
- Keeping investigation tooling inside the framework means the
  same YAML that ships the provider can serve as the capture
  harness during development — no out-of-band DevTools dance.

## Scope — start small

This proposal intentionally ships **two** actions, not three. The
third one (`capture_response_body as: <key>`) is powerful but has a
larger security surface and no concrete consumer yet. Defer it.

### Action 1: `record_requests`

Starts a recording session for the remainder of the current workflow
run (or until `dump_requests` fires). Accepts URL-pattern filters so
the capture doesn't fill memory with static assets.

```yaml
phases:
  post_login:
    - action: record_requests
      url_matches:            # required; at least one pattern
        - "bank.example/apis/externo/"
        - "bank.example/services/rest/"
      include_response_body: true   # optional, default false
      max_body_bytes: 131072        # optional, default 64KB; per response
      max_entries: 500              # optional, default 200
```

Semantics:

- Multiple `record_requests` steps are additive — each call extends
  the active filter set. One step is the common case.
- `url_matches` are substring matches, case-sensitive. No regex,
  no glob, no eval. Keep the matching rules boring.
- If `include_response_body: false`, freentonic records request
  method/URL/headers/body + response status/headers only. This is
  the default because bodies contain PII and cost memory.
- If `include_response_body: true`, freentonic calls
  `Network.getResponseBody` for each matching response and stores
  the result (capped at `max_body_bytes` — longer bodies are
  truncated with a `truncated: true` marker so the agent reading
  the dump knows it's incomplete).
- Base64-encoded bodies (CDP's `base64Encoded: true` flag) are
  decoded once, at capture time, so the dump file is always raw
  bytes (or UTF-8 text). The decoded length is what
  `max_body_bytes` measures against.
- Records are appended to a ring buffer in `@context` under a new
  `:debug_request_log` key. Overflow past `max_entries` drops the
  **oldest** entries — this keeps the interesting "what fired
  most recently" view intact.

### Action 2: `dump_requests`

Flushes the current `:debug_request_log` to a file. Designed to run
at the end of a phase (or in an `always:` equivalent if we ever add
one), so the file exists even if a later step blows up.

```yaml
phases:
  post_login:
    - action: dump_requests
      path: "/tmp/bank_capture.json"
      format: "ndjson"         # optional; "ndjson" (default) or "har"
      reset: true              # optional; clear buffer after dump, default false
```

Semantics:

- `path` is required. The path must be **outside** any directory
  named `freentonic-providers` and must not match `*.test` — a
  small set of hard-coded safety checks to reduce the odds of
  accidentally committing captures. (We cannot prevent this
  perfectly; the goal is "trip the user's conscience", not
  absolute prevention.)
- `path` is resolved against `File.expand_path` at runtime, not at
  schema load, so relative paths work from whatever CWD the user
  launched freentonic in.
- `format: "ndjson"` writes one JSON object per line. This is the
  default because it's trivially diffable, greppable, and
  streamable. Each line has the shape
  `{"request": {...}, "response": {...}, "timings": {...}}`.
- `format: "har"` writes a minimal-but-valid HAR 1.2 file. This
  exists because every tool in the world understands HAR; an
  agent or a human can load it in Chrome DevTools → Network →
  "Import HAR" and get the usual UI.
- `reset: true` clears the ring buffer after the dump. Useful if
  you want to split captures by phase.
- The action logs `[yml] dump_requests: wrote N entries to <path>`
  to stdout. Never log the entries themselves, never log the
  bodies, never log header values.

### Deferred: `capture_response_body as: <key>`

Rejected from the initial scope. The idea would be to extract a
specific response body into `@context[:captured][key]` so a later
workflow step or api_client endpoint could reference it via
`{captured.key.path.to.field}`. It's powerful — a provider could
literally say "the first fetch is whatever the web UI just asked
for" — but:

- It's a new kind of YAML dynamism (context-backed string
  interpolation into api_client endpoints), which is a schema
  surface that needs careful validation.
- It changes what can live in stage dumps. Right now
  `context[:credentials]` is the only user-data surface, and it's
  validated through `source.rb`. Adding `context[:captured]`
  means every stage dumper needs to know to scrub it by default.
- There is no concrete consumer yet — once the field names are
  known from a `record_requests` dump, they become static values
  in `extractor.rb`.

Revisit when a second provider has the same need. Probably lives
under a separate proposal doc once it does.

## Security considerations

The single thing that makes this proposal interesting from a
security angle is that it writes captured network traffic to disk.
Treat captured data with the same seriousness as HAR files:

1. **Never on by default.** `record_requests` must be explicitly
   added to a workflow. No env var, no CLI flag, no "capture
   everything silently". The YAML change should be visible in a
   diff.
2. **Never committed.** The `path` safety checks (reject paths
   containing `freentonic-providers` or inside the repo root) are
   a speed bump, not a guarantee. The agent reading this proposal
   must also enforce it in reviews. Document the rule in
   `SECURITY.md` under a new "Investigation tooling" section.
3. **Never in logs.** `[yml] record_requests: ...` and
   `[yml] dump_requests: ...` log only the action name, the
   pattern list, the entry count, and the output path. They must
   not log any URL, header, or body content.
4. **Never in stage dumps.** `context[:debug_request_log]` must be
   excluded from `--dump-raw` / `--dump-normalized` output. The
   cleanest way is to make stage dumpers explicitly opt-in to the
   keys they serialize (`context[:raw]`, `context[:normalized]`)
   and let every other key fall out. That's arguably the right
   posture anyway — right now the dumper's allowlist is implicit.
5. **No JS injection surface.** Neither action injects JS into the
   page. Both are pure CDP event subscriptions + a file write.
6. **CPU/memory limits enforced in-framework.** `max_entries` and
   `max_body_bytes` have hard defaults and hard upper bounds
   (say, 10_000 entries and 4 MB per body) that the schema
   validates at load time. A workflow that tries to set
   `max_body_bytes: 999999999` fails before Chrome launches.
7. **The `format: "har"` writer is handwritten, minimal, and
   stdlib-only.** No `chrome-har` gem, no `puppeteer-har` port —
   freentonic is zero-runtime-deps and this proposal does not
   change that. The writer emits only the fields a human or agent
   actually reads (request method/url/headers, response status/
   headers/content, page timings stubs). It does not emit any HAR
   field that HAR-the-spec considers optional if the cost is
   extra plumbing.
8. **Body decoding happens once, at capture time.** CDP returns
   `base64Encoded: true` for binary responses. We decode those
   and record the raw bytes. We do **not** record the encoded
   form in parallel. Less attack surface, less bookkeeping.
9. **Rotate after use.** `SECURITY.md` should get a new line
   reminding the user to delete capture files after use, the same
   way it already reminds them to rotate cookies after HAR
   investigation.

## Scope of change (estimated)

- **Modified:** `lib/freentonic/chrome_cdp.rb` — extend the existing
  `Network.*` event handling to collect request/response metadata
  into a ring buffer. The cookie capture already sits here, so most
  of the plumbing is additive, not a rewrite.
- **Modified:** `lib/freentonic/browser_workflow_runner.rb` — add
  `when "record_requests"` and `when "dump_requests"` branches.
  ~60 lines including helpers.
- **New file:** `lib/freentonic/debug_request_writer.rb` — the
  ndjson + har serializers. Isolated so the workflow runner
  doesn't bloat.
- **Modified:** `lib/freentonic/workflow_schema.rb` — shape
  validation for both new actions in `validate!`: required keys,
  type checks, hard upper bounds on `max_entries` and
  `max_body_bytes`, refuse `path` values that look like repo
  paths (contain `freentonic-providers/` or resolve inside the
  current git repo).
- **Modified:** `lib/freentonic/engine.rb` — exclude
  `context[:debug_request_log]` from stage dumps. This might be
  the right time to switch stage dumpers to an explicit allowlist.
- **Modified:** `test/browser_workflow_runner_test.rb` — new tests
  against a `FakeSession` that replays a hand-crafted sequence of
  `Network.requestWillBeSent` + `Network.responseReceived` +
  `Network.loadingFinished` events.
- **New file:** `test/debug_request_writer_test.rb` — round-trip
  tests for ndjson and har outputs.
- **Modified:** `test/workflow_schema_client_test.rb` — negative
  tests for: missing `url_matches`, `max_entries` over the cap,
  `path` inside a repo.
- **Modified:** `README.md` — new "Investigation tooling" section
  explaining when to use these actions (during provider authoring
  only; never in a shipped workflow).
- **Modified:** `SECURITY.md` — new "Investigation tooling" section
  matching the invariants above.
- **Modified:** `examples/example_bank.yml` — a commented-out
  `record_requests` + `dump_requests` pair showing the
  investigation pattern.

No new runtime dependencies. Everything above is CDP events +
stdlib JSON + stdlib File.

## Test plan

- `test_record_requests_captures_matching_urls` — fake three
  network events (two matching, one not), assert the ring buffer
  holds two.
- `test_record_requests_respects_max_entries` — push `max_entries
  + 5` events, assert oldest were dropped, newest retained.
- `test_record_requests_truncates_large_bodies` — fake a response
  with body larger than `max_body_bytes`, assert the stored body
  is truncated and flagged `truncated: true`.
- `test_record_requests_decodes_base64_once` — fake a response
  with `base64Encoded: true`, assert stored body is the decoded
  form, no duplicate encoded copy.
- `test_record_requests_does_not_record_when_include_body_false`
  — fake a matching response, assert no `Network.getResponseBody`
  call was dispatched.
- `test_dump_requests_ndjson_roundtrip` — write a buffer of three
  entries, read back line-by-line, assert each parses as JSON and
  the entries match.
- `test_dump_requests_har_is_valid` — write a buffer, read back,
  assert the result has `log.version`, `log.entries[*].request`,
  `log.entries[*].response`, and that DevTools would accept it
  (validate shape, not semantics — no browser in the test loop).
- `test_dump_requests_reset_clears_buffer` — with `reset: true`,
  assert the in-memory buffer is empty after the dump.
- `test_dump_requests_rejects_repo_path` — path containing
  `freentonic-providers/` raises `UserError` at action dispatch.
- `test_workflow_schema_rejects_record_requests_without_url_matches`
  — schema-level.
- `test_workflow_schema_rejects_record_requests_over_entry_cap`
  — schema-level.
- `test_dump_requests_does_not_log_entries_or_bodies` — capture
  stdout and stderr during a dump, assert neither contains any
  entry URL, header, or body content.
- `test_debug_request_log_excluded_from_stage_dumps` — run a
  minimal pipeline with an active recording, dump the stage,
  assert the dump file does not contain the log.

All tests stub CDP with the existing `FakeSession` pattern. No
live Chrome.

## Open questions for the framework-agent

1. **Ring buffer vs unbounded list.** The proposal assumes a ring
   buffer for `max_entries` because "most useful investigations
   want the *last* N requests". An unbounded list with a hard
   refuse-to-record past N is simpler. Which matches real
   investigation workflows better? Ask the consumer (me, next
   session) before deciding.
2. **Stage dump allowlist.** Switching stage dumpers from "dump
   everything except X" to "dump only Y" is cleaner but is a
   small breaking change for anyone who snapshotted
   `context[:foo]` via a plugin. Worth doing now or should we
   stick with a denylist for this one key? Framework-agent's
   call.
3. **HAR minor version.** HAR spec stopped at 1.2 in 2012 and
   nobody uses anything newer. Stamp `log.version = "1.2"` and
   move on — no reason to invent a dialect.
4. **Phase lifetime vs run lifetime.** Currently the proposal
   says "recording lasts until `dump_requests`". An alternative
   is "recording lasts for the current phase, auto-flushed at
   phase end". The latter is more foolproof (no way to forget
   the dump step) but introduces an implicit file write that's
   harder to audit in the YAML. Lean toward the explicit
   `dump_requests` step for now — foolproofing can come later
   if real usage shows it's needed.
5. **Relationship with `capture_header`.** The existing
   `capture_header` action reads a single header from a single
   in-flight request and stashes it in `context`. Could it be
   reimplemented in terms of `record_requests` + a reducer?
   Probably yes, but that's refactor scope, not this proposal.
   Leave the two actions side-by-side.

## Handing back

When implementing this, the framework-agent should:

- Read this proposal end-to-end.
- Read the consuming provider's investigation doc for context —
  specifically, confirm that a `record_requests` on the relevant
  API paths + `dump_requests` to `/tmp/` would surface the
  response field names that the investigation is missing.
- Validate the CDP event plumbing against a FakeSession that
  replays a real-shaped event sequence — do not test against a
  live browser.
- Run `bundle exec rake test` in `freentonic` and in
  `freentonic-providers` before considering the change done.
- Not open the Issue or PR directly. Produce them as markdown
  drafts in the chat output, let the user review and file them.
