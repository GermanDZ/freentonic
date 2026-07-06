# Changelog

All notable changes to freentonic are documented here.

With providers living in a separate repo, the workflow YAML dialect and
the invoke-server API **are** freentonic's public contract — this
changelog is their version signal. Every release below corresponds to a
`version.rb` bump and a matching `vX.Y.Z` git tag. What the workflow
`version: 1` line promises (additive keys never bump; renames get a
one-release dual-accept window before `version: 2`) is spelled out in
[docs/workflow-schema-versioning.md](docs/workflow-schema-versioning.md).

## 0.18.0 — Tier B pure functions + provider-Ruby capability gate

Completes the pure-functions program (Asks 9–10). Two changes land together.

**Tier B `apply:` functions for declarative normalizers.** Adds the pure
functions the last escape-hatch normalizers needed to become
`normalize: plan:` — `collapse_prefix_dups`, `negate`, `subtract`,
`join_present`, `reformat_date`, `remove_whitespace`, `append_suffix` —
plus `Freentonic::PathDig`, the shared Hash/Array/entity dotted-path reader
now used by the extract-plan interpreter, the template scope, and the Fn
layer. Each is registered in `Freentonic::Fn` and born covered by the
purity harness. Workflow-dialect impact is additive: these are new
`apply:` names, no existing key changes.

**Provider Ruby is now opt-in — `FREENTONIC_ALLOW_PROVIDER_RUBY`.**
Declarative plans are the default; the `extract: ruby:` / `normalize: ruby:`
escape hatch and `api_client.ext` are a supported but gated authoring mode.
A server is declarative-only unless started with
`FREENTONIC_ALLOW_PROVIDER_RUBY=1`, which makes "no provider-authored code
runs during a sync" a runtime-enforced invariant. The gate fires at run
entry (before Chrome launches or the api_client is built), precise to the
planned stages, so a `--from-normalized` replay that skips a
`normalize: ruby:` stage isn't blocked. `--lint` stays mode-agnostic and
notes which stages need the opt-in.

> **BREAKING for servers running a Ruby workflow.** Any workflow still using
> `extract: ruby:`, `normalize: ruby:`, or `api_client.ext` now **fails at
> run start** unless `FREENTONIC_ALLOW_PROVIDER_RUBY=1` is set. Fully
> declarative workflows (Revolut, ING, Unicaja) are unaffected. Set the env
> var on any deployment that syncs a Ruby-normalizer provider (e.g. Fintonic).

## 0.17.2 — pass GEM_HOME/GEM_PATH through to the workflow subprocess

Fixes a follow-up to 0.17.1: shipping tzinfo in the image wasn't enough —
named-zone workflows *still* failed with the same "needs the tzinfo gem"
error. Root cause: `InvokeRunner#build_env` spawns the workflow subprocess
with `Process.spawn(env, ..., unsetenv_others: true)`, and its `env`
whitelist (`PATH`/`HOME`/`LANG`/`DISPLAY`/`FREENTONIC_*`) didn't include
`GEM_HOME`/`GEM_PATH`/`BUNDLE_APP_CONFIG`. So gems installed outside
Ruby's compiled-in default path — like the image's gem-installed tzinfo —
were invisible to the child even though `gem list` and an interactive
shell found them fine. `build_env` now forwards `GEM_HOME`, `GEM_PATH`,
and `BUNDLE_APP_CONFIG` from the server process's own environment when
they're set.

## 0.17.1 — ship tzinfo in the Docker image (named-zone fix)

Fixes a 0.17.0 regression: a workflow booking dates in a named IANA
timezone (`output_timezone: Europe/Madrid`) failed at normalize time in
the deployed image with `timezone … needs the tzinfo gem`. Root cause: the
runtime image installs *no* gems (freentonic runs straight off stdlib —
there's no `bundle install`), so neither repo's Gemfile `tzinfo` reached
it. Named IANA zones can't be resolved without tzinfo.

- The Docker image now whitelists **tzinfo** + **tzinfo-data** (pure-Ruby,
  the engine behind Rails' time zones; tzinfo-data bundles the zone DB so
  there's no floating system-tzdata dependency), gated by a new
  `INCLUDE_TZINFO` build arg (default `1`). A build-time smoke test fails
  the build if a named zone can't resolve. Build with
  `--build-arg INCLUDE_TZINFO=0` for a strictly stdlib image.
- No gem-code change: freentonic still has no *required* runtime
  dependency, and UTC / fixed-offset workflows need nothing. Rebuild + 
  redeploy the image to pick up the fix.

## 0.17.0 — `parse_date` timezones (input/output zones)

`parse_date` gains explicit timezone control, and — importantly — its
default is now **deterministic**. The canonical model stores a calendar
`Date`, so the only question a timezone answers is *which zone's calendar
day an instant falls on*. Additive; no `version:` bump.

- **Behavior change (determinism fix):** a Unix timestamp used to reduce
  to a calendar day via `Time.at(ts).to_date` — the **process's local
  TZ** — so the same raw payload could normalize to a different `date` on
  a laptop vs a UTC CI runner, breaking `--from-raw` reproducibility. It
  now defaults to **UTC**. Only providers parsing absolute instants are
  affected; every Spanish bank (ING, Unicaja) and Fintonic send date-only
  strings, which are timezone-immune. Revolut (epoch-ms / Zulu ISO) is the
  only affected provider, and its dates are unchanged under UTC.
- **`parse_date` / `Fn` params `input_timezone:` + `output_timezone:`**
  (both default UTC):
  - `output_timezone` buckets any absolute instant (Unix timestamp, or an
    offset-bearing datetime like `…Z` / `…-05:00`) into its calendar day —
    the display/booking zone.
  - `input_timezone` interprets an offset-*naive* datetime string
    (`"2024-03-15 23:30:00"`, no offset) as local time in that zone before
    bucketing. Date-only inputs and already-instant inputs ignore it.
- **Zone grammar** — `UTC` (default) and fixed offsets (`"+01:00"`) are
  pure stdlib; named IANA zones (`"Europe/Madrid"`, DST-correct) use the
  **optional** `tzinfo` gem. A named zone without tzinfo raises a clear,
  actionable error (and `--lint` flags a bad/unavailable zone declared in
  `config.yml`) rather than failing obscurely mid-sync.
- Providers set `input_timezone:` / `output_timezone:` in `config.yml` and
  thread them through `apply: parse_date` (see Revolut).

## 0.16.0 — `normalize: plan:` (Ask 8)

Normalization goes declarative ([docs/normalize-plan.md](docs/normalize-plan.md)):
a provider can now express its whole raw→canonical transform in
`workflow.yml`, deleting its `normalizer.rb`. Revolut is the proof —
migrated in freentonic-providers with golden-parity coverage. Additive;
no `version:` bump.

- **`normalize: plan:`** — the extract-plan step grammar minus `fetch:`
  (statically excluded AND runtime-guarded: no api_client exists), so a
  normalize plan is a *total, offline* computation — raw in, canonical
  out, `--from-raw`-replayable forever. Scope seeds: `raw`, `config`
  (the provider's config.yml), `today` — deliberately not
  `now_ms`/`from_ms`, which would silently break replay. `output:` is
  restricted to `accounts:` / `transactions:` / `liabilities:`; the
  stage assembles the CanonicalPayload envelope itself with config.yml's
  `scraper_version`. Mutually exclusive with the `ruby:`/`class:` escape
  hatch (which Ask 10 deletes).
- **Verb-set parameterization** — the shared step validator takes an
  allowed-verbs list; extract plans and elevate keep the full set.
- **`index_by: where:` operator matchers** — a matcher value may now be
  an operator hash from the `when:` set (`{ iban: { present: true } }`),
  expressing "first element carrying this field", which literal equality
  cannot.
- **Entity digging** — templates and `select:` paths can walk the
  declared members of a canonical entity (`{account.id}`), never an
  arbitrary send, so a plan chains `build_account` into the
  `build_transaction`s attached to it.
- **New builtins** — `compact`, `flatten`, `pluck`, `join` (the
  whole-token-safe form of string interpolation), `strip`.

## 0.15.0 — `Fn` registry + the `apply:` verb (Ask 7)

First step of the pure-functions program
([docs/pure-functions-plan.md](docs/pure-functions-plan.md)): a registry
of named **pure functions** and one shared verb to call them from any
plan context. Groundwork for `normalize: plan:` (Ask 8) — the goal is
deleting every per-provider `normalizer.rb`. Additive; no `version:` bump.

- **`Freentonic::Fn`** — a closed, freentonic-owned registry of pure
  functions: args in → value out, no I/O, no client, no clock, no input
  mutation. Purity is enforced, not asked: `Fn.call` deep-freezes every
  resolved arg, so a mutating impl raises `FrozenError` instead of
  corrupting a shared plan binding. Every definition must declare a
  description, typed params, an impl, and **at least one executable
  example** — the registry test harness runs all examples (twice each,
  asserting identical results), so a function cannot exist without being
  born covered.
- **`apply: <function> / args: / as:`** — new verb in the shared plan
  step grammar, usable in `extract: plan:` steps, `for_each do:` blocks,
  and the `elevate:` phase. Dispatch is a registry lookup (never a `send`
  off YAML); the registry plays the same whitelist role for `apply:` as
  the declared-endpoint list does for `fetch:`. Because `args:` is a
  literal YAML hash, `--lint`/load statically reject an unknown function,
  an undeclared parameter, a missing required parameter, or an unbound
  `{ref}`.
- **Tier A builtins** — registrations over the existing tested
  helper/builder logic: `cents`, `cents_to_amount`, `parse_date`,
  `parse_timestamp_ms`, `map_status`, `pick`, `extract_fields`,
  `first_present`, `pan_last4`, `compact_whitespace`,
  `spanish_iban_portable_keys`, `card_pan_portable_keys`,
  `build_account`, `build_transaction`, `build_liability`.

## 0.14.0 — Extract-plan `lookup:` (dynamic-key map read)

The one idiom the Ask 5 verbs turned out not to cover, and the last thing
standing between ING and a deleted `extractor.rb`: a **dynamic-key map
read**. `index_by:` builds a `Hash`, but nothing read it back — `select:`'s
`path:` is a static string and a `when:`/`skip_when:` gate compares a
binding against a *literal*, never against another binding. So a plan could
iterate legacy products (carrying `type` for kind routing but no v2 UUID)
or modern products (carrying identifiers but no `type`) — never join them.
Additive; no `version:` bump.

- **`lookup: { from:, key:, default? }`** — read a bound map with a
  runtime-resolved key. `from:` names a `Hash` (typically from `index_by:`);
  `key:` is a value template (`{product.uuid}`) resolved against the current
  scope, so inside a `for_each` the same step reads a different entry each
  iteration. The declarative form of `uuid_map[product["uuid"]]`. A missing
  key — or an unbound / non-`Hash` `from:` — binds `default:` when given,
  else `nil`, so a downstream `skip_when:`/`warn:` routes on the absent
  value. Read-only: it digs an already-built binding, computing nothing
  (same filter/dig/index altitude as `select:`).
- Statically validated at load + `--lint` (`from:` bound by an earlier
  step, `key:` template refs bound, non-empty `as:`).

## 0.13.0 — Declarative extract plans + session elevation

Providers can now express extraction and PSD2 session elevation entirely
in `workflow.yml` — the only Ruby a provider need ship is an optional
normalizer. Highlights: the `extract: plan:` grammar (Phase 1 + 2 + the
`index_by`/message/`skip_when`/`on_error` verbs below), the `elevate:`
session-elevation phase, and request headers + `PUT` on declared
endpoints. Plus structured run events, export resilience, and the async
`/invoke` API. All additive to the workflow dialect — no `version:` bump.

### Extract-plan verbs: `index_by`, `note`/`warn`/`abort`, `skip_when`, fetch `on_error`

The last idioms an orchestration-only extractor needed that the plan
grammar couldn't express — enough that ING's `extractor.rb` can be
retired. All additive; no `version:` bump.

- **`index_by: { from:, key:, value: }`** — build a `Hash` from a bound
  list. `key:`/`value:` are a dotted-path String or a *find-by-field* spec
  (`{ path:, where:, pick: }` — dig to a list, find the element matching
  `where:`, `pick:` a field). Nil-key / blank-value entries are dropped.
  The declarative form of a hand-written lookup-map build.
- **`note:` / `warn:` / `abort:` message verbs.** Emit an operator
  breadcrumb (stdout / stderr / raise `UserError`), with embedded `{token}`
  interpolation and an optional `when:` gate — so a preflight guard is
  `abort: "…" when: { bearer: { absent: true } }`.
- **`skip_when: <gate>`** (inside `for_each.do`) — drop the current
  iteration when the gate passes; contributes nothing and short-circuits
  the rest of the iteration. Pairs with `warn:`/`note:` for loud skips.
- **`fetch … on_error: { abort: | warn: }`.** A custom failure policy that
  covers `SessionExpired` too: `abort` raises a `UserError` with an
  operator message (for a critical fetch whose silent failure would
  mislead downstream — an empty `/position-keeping` reads as "all accounts
  deleted"); `warn` notes it and degrades to `default:`.
- **Array indices in plan paths.** `select:`/`output:` dotted paths now
  index Arrays with an integer segment (`accessTokens.0.accessToken`).
- Statically validated at load + `--lint` (binding resolution,
  find-by-field spec shape, one-of `abort`/`warn`, message refs).

### Session elevation (`elevate:` phase)

A new lifecycle stage — **Connect → Elevate → Extract → Normalize →
Export** — for the session-elevation work that isn't login and isn't
extraction: a PSD2 SCA handshake that mutates the session (operator
approval + Bearer rotation) before the fetch loop. It lets a provider
express declaratively what previously forced an `extractor.rb`. No-op
when a workflow declares no `elevate:` block.

- **`elevate:` block.** Reuses the `extract: plan:` step grammar
  (`fetch`/`select`/`for_each`/`let`/`concat`/`dedup_by`, each optionally
  `when:`-gated, seeded with `from_date`/`today`/`lookback_days`/…) and
  adds two session-affecting step kinds a locked-down extract plan is
  forbidden from having. It has no `output:` — its product is the mutation
  it leaves on the client.
- **`await_operator_approval: { message:, timeout: }`.** Pauses mid-flow
  for a human to approve an out-of-band challenge (SCA push) on their
  phone, surfaced through the same `RemotePromptStore` the invoke server
  watches. No operator channel or a timeout → the step fails (never hangs
  a headless run), feeding `on_failure:`.
- **`rebind_credential: { header:, host:, value: }`.** Installs a value
  derived from a fetched response as an auth header on the client via
  `update_auth_headers!` — the one sanctioned session mutation, the
  declarative form of ING's imperative Bearer rotation. An empty/nil
  resolved value fails the step.
- **`when:` + `on_failure: degrade|abort`.** A block-level `when:` gate
  (e.g. `{ lookback_days: { gt: 90 } }`) runs elevation only when needed;
  `degrade` warns and continues with the un-elevated session, `abort` (the
  default) fails the run.
- **Shared client instance.** The Elevate stage builds the api_client,
  stashes it in `context[:api_client]`, and the Extract stage reuses that
  instance — so a rebind performed during elevation is visible to the
  fetch loop. (Previously Extract minted a fresh client per run.)
- **Richer templating for elevate strings.** `message:`/`value:` support
  embedded `{tokens}` inside surrounding text and array indices in dotted
  paths (`{refreshed.accessTokens.0.accessToken}`); array-index digging
  also now works in plan `select:`/`output:` paths. The plan grammar's
  whole-token rule for structured args is unchanged.
- **Statically validated + additive.** The block is checked at load and
  `--lint` (endpoint whitelist, binding resolution, embedded-token refs,
  operator/operand types, `on_failure:` domain). No `version:` bump; a
  workflow without `elevate:` is untouched. See
  [docs/elevate-phase.md](docs/elevate-phase.md).

### Declarative extractor plans (`extract: plan:`)

A provider whose extractor is pure orchestration — call an endpoint, loop
over the rows, call another endpoint per row, assemble a hash — can now
express it declaratively instead of shipping an `extractor.rb`.

- **New `extract: plan:` form.** A small, closed grammar
  (`fetch` → `select` → `for_each`/`yield` → `output`) over the
  workflow's existing declarative `api_client` endpoints. `from_date`,
  `from_ms`, and `now_ms` are pre-seeded bindings; `{name}` /
  `{name.dotted.path}` templates thread values between steps; `safe:` +
  `default:` tolerate non-critical fetch failures (a `SessionExpired`
  still propagates). Mutually exclusive with the `{ruby:, class:}` escape
  hatch, which is unchanged and still the right tool for imperative
  extractors (SCA handshakes, `raw_request`, mid-flow header rotation).
  See [docs/extract-plan.md](docs/extract-plan.md).
- **Fully statically validated.** Workflow load and `--lint` check
  (offline) that `fetch:` names a declared endpoint, every `{token}`
  resolves to a binding, each `for_each` yields, and exactly one extract
  form is declared — so a typo'd endpoint or dangling reference fails
  before login. The interpreter dispatches on a fixed verb set and
  `fetch:` resolves only against declared endpoint names: a plan can
  never reach an arbitrary client method.
- **Additive.** No `version:` bump — existing `{ruby:, class:}` workflows
  are untouched.

#### Phase 2 — data-shaping + conditional verbs

The grammar grew the verbs that take the remaining orchestration-only
providers (Fintonic, Unicaja) to zero extractor Ruby. Only ING — the
genuinely imperative provider — keeps an `extractor.rb`.

- **Data-shaping.** `let: <name>` binds a value from `value:`,
  `coalesce:` (first non-nil of an ordered list — the declarative
  `a || b || "lit"`), or `days_ago: N` (`today - N`). `concat: [a, b]`
  merges bound arrays (each `Array()`-coerced). `dedup_by: key | [keys]`
  dedupes an array first-wins, with a fallback-key list for
  cross-endpoint field spellings and **nil-key passthrough** (a row
  missing the key is always kept, never collapsed).
- **Conditionals.** Any step may carry a `when: { binding: { op: operand } }`
  gate reusing the browser-phase `when_context` operator set (`gt`/`gte`/
  `lt`/`lte`, `eq`/`neq`, `present`/`absent`). A false gate makes the step
  a no-op — a downstream `concat:`/reference to its `as:` reads `[]`/nil.
  It is deliberately not an expression language (no string predicates); a
  classify-and-drop that needs string matching belongs in the normalizer.
- **Two more seed bindings.** `today` (a `Date`) and `lookback_days`
  (`today - from_date`) join `from_date`/`from_ms`/`now_ms`, so a `when:`
  gate can toggle an extended-history fetch on long runs.
- **Statically validated + additive.** The new verbs are checked at load
  and `--lint` (source binding resolution, one-`let`-source-only, known
  operators + operand types). No `version:` bump.

### Declarative endpoint request headers + `PUT`

The `api_client.endpoints` block gained request headers and a third verb,
so endpoints that previously forced a provider to reach for
`raw_request` — the PSD2 SCA handshake calls being the last holdouts —
can now be declared statically.

- **`headers:` on any endpoint.** A name→value map whose values are
  interpolated with the same grammar as `params:`/`form:`/`json:`
  (`{name}`, `{name|date}`, `{name|iso}`); static values pass through. A
  header naming an absent kwarg resolves to nil and is dropped rather than
  sent empty. Headers apply *after* the client's `auth_headers`, so an
  endpoint header overrides an auth header on a name collision — the same
  precedence `raw_request` already uses.
- **`method: PUT`.** Joins `GET`/`POST` with `form:`/`json:` body and
  `headers:` support (no pagination — `PUT` is for idempotent writes like
  the SCA commit). A previously-silent gap is also closed: an endpoint
  with an unsupported `method:` now raises at workflow load instead of
  defining nothing.
- **Additive.** No `version:` bump; endpoints without `headers:` are
  unchanged.

### Structured run events + minimal observability

A structured channel for run telemetry, plus request-level and aggregate
visibility on the invoke server.

- **`Reporter` event stream.** Pipeline runs now emit typed events
  (`pipeline.start`, `stage.start` / `stage.finish` / `stage.error`,
  `phase.start` / `phase.finish`, `step`), each carrying `elapsed_ms` and,
  for stages/phases, a `duration_ms`. Two sinks: a concise human
  stage-timing summary on stdout (the CLI default), and NDJSON to
  `<run_dir>/events.ndjson` (0600) when `FREENTONIC_RUN_DIR` is set (i.e.
  under the invoke server). `step` events record only the YAML action name
  and phase — never a resolved value, so no secret or URL argument is
  logged. A broken sink can never fail a run.
- **Server access log.** One line per HTTP request to the server's logger —
  `method path status ms` — with no bodies, no query string, and never the
  bearer token. Covers every route, including the streaming `/log` and
  `/recording` endpoints.
- **`GET /metrics`.** New authenticated endpoint exposing cumulative,
  process-lifetime counters: `runs_total`, `duration_ms_total` /
  `duration_ms_avg`, and `by_status` / `by_error_kind` buckets.
- **`queued` vs `running` in `/status`.** Each in-flight entry is now tagged
  `queued` or `running`. `queued_ms` measures pure queue wait (it freezes
  once the run starts); `started_at` / `elapsed_ms` appear only once running
  and measure child run-time — no longer inflated by queue wait.

### Export resilience

A failed export costs a whole bank login to redo, so transient failures no
longer sink a run outright.

- **HTTP exporter retries transient failures.** Connection-refused,
  connect/read timeouts, and `5xx` responses are retried with exponential
  backoff (2 retries by default → 3 attempts; `--export-* retries:` and
  `retry_base_delay:` are configurable). DNS failures (`SocketError`) and
  `4xx` are treated as permanent — retrying can't help — and raise
  immediately. Each retry logs a one-line `⏳ … retry N/M` notice.
- **Aggregate export errors.** When more than one exporter fails, the Export
  stage now raises a single error naming *every* failed exporter and
  carrying each message, instead of re-raising only the first and dropping
  the rest. A lone failure is still re-raised verbatim.
- **Exporter progress uses the injected stream.** The HTTP exporter's
  status/retry/success lines now go through the engine's injected output
  stream (like every other stage) rather than global `$stdout`, so they land
  in the run log and are capturable.

### Fixed

- **http exporter allows cleartext + token to private/loopback receivers.**
  The exporter refused to send a bearer token over cleartext `http://`
  unconditionally, which blocked a legitimate topology: a same-host
  container-network push (`http://kamal-proxy/push/…`) with TLS terminated
  at an upstream edge proxy. It now permits cleartext + token when the
  receiver host resolves **entirely** to loopback/private/link-local
  addresses (the token can't leave the host's trust boundary), still warns,
  and continues to refuse for any public/routable host — failing closed on
  an unresolvable host. Matches the existing "localhost receivers" intent
  for the no-token case.
- **Chromium is pinned to a known-good version (`148.0.7778.96-1~deb12u1`).**
  The Dockerfile installed `chromium` unpinned, so each image rebuild
  floated the browser to whatever bookworm-security currently shipped. A
  redeploy pulled `150.0.7871.46-1~deb12u1`, which **SIGTRAPs (exit 133)
  on launch** in the container — Chrome never opens the remote-debugging
  port, so every scrape failed with `Chrome did not respond on debug port
  after 45s` (exit 1 / `user_error` downstream). The browser is now
  installed at a fixed version from a Debian snapshot and `apt-mark hold`;
  `CHROMIUM_VERSION` / `CHROMIUM_SNAPSHOT` are build ARGs so a browser
  bump is a deliberate, tested change. An unpinned external dependency
  could otherwise take the whole bridge down with no code change.

### Container hardening + token lifecycle

Defense-in-depth for the invoke-server container, and a token model that
supports zero-downtime rotation.

- **Hardened container.** The wrapper (`docker-run-freentonic.sh server`)
  and the documented raw `docker run` now apply `--cap-drop ALL`,
  `--security-opt no-new-privileges`, and a `--read-only` root filesystem
  with the minimum tmpfs mounts Chrome + Xvfb need (`/tmp`, `~/.config`,
  `~/.local`, `~/.pki`; `/dev/shm` comes from `--shm-size`). Chrome runs
  `--no-sandbox`, so a renderer compromise already shares the `freentonic`
  uid — this denies it capabilities, privilege escalation, and a writable
  rootfs to persist on. Verified against the ING anti-detection flag set.
- **Token set instead of a single token — breaking config change.** The
  server now accepts *any* of a configured set of bearer tokens.
  `InvokeServer` takes `invoke_tokens:` (was `invoke_token:`); tokens are
  assembled by `InvokeServer.load_tokens` from `--invoke-token`
  (repeatable), `FREENTONIC_INVOKE_TOKEN` (comma-separated), and
  `--invoke-token-file` / `FREENTONIC_INVOKE_TOKEN_FILE` (a file, one token
  per line, `#` comments + blanks ignored). To rotate: add the new token as
  a second line, restart, cut clients over at their own pace, then drop the
  old line — no simultaneous cutover.
- **Token out of `docker inspect`.** When `FREENTONIC_INVOKE_TOKEN_FILE`
  (a host path) is set, the wrapper mounts it read-only and passes only the
  in-container path via `-e`; the secret no longer appears in
  `docker inspect`. `-e FREENTONIC_INVOKE_TOKEN` still works for local dev,
  with a note that its value is inspectable.

**Migration:** embedders constructing `InvokeServer` directly must pass
`invoke_tokens: [tok]` instead of `invoke_token: tok`. Operators using the
wrapper or the plain `FREENTONIC_INVOKE_TOKEN` env var need no change.

### Async `/invoke` (202 + poll) — **breaking API change**

`POST /invoke` no longer blocks for the whole run. It now validates the
request synchronously (charset / containment / export errors still come
back as `4xx` on the POST), then returns **`202 Accepted`** with
`{"run_id": ..., "status": "queued"}` and runs the workflow in the
background. Poll the new **`GET /runs/{run_id}`** for lifecycle and result:

- `queued` → `{status, submitted_at}`
- `running` → `{status, started_at, elapsed_ms}`
- `done` → `{status, exit_code, error_kind, duration_ms, artifacts,
  log_path, warnings, finished_at}` (a non-zero `exit_code` is still a
  `done` under `200` — the run ran, something inside it failed)
- `error` → `{status, error, finished_at}` (server/containment failure)
- `cancelled` → `{status, finished_at}`
- unknown / evicted `run_id` → `404`

Why: a synchronous call that can block up to two hours forces huge client
read-timeouts, is fragile through proxies, and couples the DoS surface to
run duration. Worse, a client that disconnected mid-run did **not** cancel
it — the bank login proceeded for nobody. The lifecycle is now decoupled
from the HTTP connection.

Preserved and new behavior:

- **Serialization is unchanged.** A single worker thread runs one invoke
  at a time under the same `@invoke_mutex`; `/profiles/prune` still queues
  behind a live invoke. Concurrency is still v1-strict.
- **Bounded backlog.** Accepted-but-unfinished runs are capped
  (`max_queued_runs`, default 128); over the cap `/invoke` returns `503`
  with `retry_after`. Finished runs are retained in memory
  (`max_retained_runs`, default 256) and FIFO-evicted; a caller that polls
  after eviction falls back to reading artifacts off the runs dir.
- **`/cancel/{run_id}` now also cancels a still-queued run** (previously
  only running ones), atomically, before any Chrome child is spawned.
- **Shutdown** drains the worker within the existing grace window and
  aborts anything still queued.
- Inline credentials are scrubbed from the retained run record as soon as
  the run finalizes — a completed run kept for polling holds no secret.

**Migration:** clients that read the result from the `/invoke` response
must switch to polling `GET /runs/{run_id}`. Drop the oversized
`read_timeout` (only needs to cover request validation now). `/healthz`
`in_flight` and `/status` continue to count queued+running work.

### HTTP export over cleartext + `note` secret hygiene

- The http exporter now **refuses** to send a bearer token over a
  cleartext `http://` URL (the payload and `Authorization` header would
  otherwise cross the wire unencrypted). Cleartext without a token still
  works but prints a warning.
- `note` / `note_if_selector` messages are printed **verbatim** —
  `secret()` is no longer resolved in them, so a note can't leak a
  resolved secret into the persisted run log.

### CSV exporter: neutralize formula injection

Cells whose first character is a spreadsheet formula trigger
(`= + - @ \t \r`) are now prefixed with a leading apostrophe so Excel /
Sheets treat them as text — merchant names and transfer memos are
attacker-influenceable bank text, so `=HYPERLINK(...)` / `@SUM(...)` would
otherwise execute on open. Plain numeric literals (including negative
amounts) are left untouched so financial columns stay summable.

### Confine provider ruby to the workflow's directory subtree

`extract.ruby`, `normalize.ruby`, and `api_client.ext.file` now must
resolve inside the workflow YAML's own directory subtree (the documented
"ship code alongside your YAML" layout). An absolute or `../` path — or a
symlink — that escapes the subtree is rejected with a `UserError` at load
time (and flagged by `--lint`). Shrinks the residual attack chain where a
token-holder names an export artifact `foo.rb` in a writable run dir and
points a ruby reference at it.

### Invoke server: confine `credentials.file` to a secrets root

`credentials.file` is now resolved under a configured secrets root
(`/workspace/secrets`, `--secrets-dir`) with the same expand_path/realpath
containment `workflow` gets — absolute paths are re-rooted, symlinks
escaping the root are rejected. Previously any absolute container path was
accepted, and its content hash leaked through the derived `profile_key` on
`/status` as a file-content confirmation oracle. **Breaking:**
`credentials.file` is now a path relative to the secrets root, not an
arbitrary absolute path.

### Invoke server: bound pre-auth request reads (slow-drip DoS)

The request reader now enforces a 30s absolute wall-clock deadline from
accept to end-of-body, independent of the per-select idle timeout.
Previously a client trickling one byte per 29s reset the idle window
forever and pinned a connection slot without authenticating; enough such
sockets could 503 every endpoint including `/healthz`.

### `freentonic --lint` — offline workflow validation

A dry-run that statically validates a workflow without launching Chrome
or hitting the bank. Checks the schema, that `extract:`/`normalize:`/ext
ruby loads and its classes resolve, that `api_client:` builds into a
client class, that every `credentials.require` key is captured by some
action's `as:`, and that every `secret(NAME)` has a `secrets:` entry
(warning). Exit `0` clean, `1` on error. Previously the earliest full
check of a workflow was a live login.

### Action registry + exhaustive load-time validation

Every workflow action now lives in a single declarative registry
(`WorkflowActions`) that lists its required and optional keys. Schema
validation is driven from it, closing two long-standing gaps:

- **Unknown actions fail at load, not mid-run.** A typo like
  `navigat` previously passed validation and only died at the runner's
  dispatch `else` branch — possibly *after* the operator completed 2FA.
  It now raises a `UserError` at load time listing the known actions.
- **Required keys are checked for all ~33 actions**, not just the ~13
  that had bespoke validators. Provider authors get a precise
  `<action> requires <key>:` error in milliseconds.

A drift-guard test keeps the registry and the runner's dispatch in
lockstep — neither can list an action the other omits.

### `await_external_approval` prompt kind

A third SCA pattern alongside `input` and `confirm`: the workflow polls
for an out-of-band condition — e.g. the operator approving a PSD2
challenge in the bank's mobile app — and resumes on its own when it
fires. The prompt withdraws itself once satisfied; the operator can also
submit an empty body as a manual fallback. Surfaces as `kind: "await"`
on `GET /runs/{run_id}/prompts` (same submit shape as `confirm`).

### Hardening (invoke server + pipeline)

- Reject `run_id` / `profile_key` equal to `.` or `..` — a path
  containment escape on the write path. `InvokeRunner#run` gains a
  defense-in-depth containment check.
- `dump_requests` capture files (raw headers, cookies, response bodies)
  are written `0600` instead of world-readable.
- Graceful shutdown actually drains: on SIGTERM the server SIGTERMs the
  in-flight child's process group and joins the handler for up to 20s,
  so Chrome tears down cleanly instead of by container SIGKILL. The
  deployment doc no longer overstates the old (no-op) behavior.
- Reject prompt submissions for a run that is no longer in flight (a
  crashed child can no longer strand an OTP on disk); skip expired
  prompts in `GET /runs/{run_id}/prompts`.
- Three uncaught-exception holes now become clean `UserError`s instead
  of raw backtraces (sometimes after the operator completed 2FA):
  workflow `step.fetch` `KeyError`s, malformed
  `--from-raw`/`--from-normalized` JSON, and `ApiClient::SessionExpired`
  escaping Extract. Introduces a typed `ChromeCdp::Error`.

## 0.12.0 — Declarative cursor pagination

Any endpoint can declare `pagination: { kind: cursor, … }` in
`workflow.yml` and let the framework walk the loop, replacing the
imperative cursor-pagination Ruby every provider was carrying. Two
flavors share one engine (`ApiClient#ep_paginate_by_cursor`):

- **Envelope cursor** — extract the next cursor from a response path
  (`cursor_from_response`), continue while a `response_path` equals a
  value (Unicaja's `masMovimientos` pattern).
- **Row cursor** — derive the cursor from the last row via a field
  alias chain with optional `timestamp_ms` coercion
  (`cursor_from_last_row`), continue while `cursor_gt` a bound
  (Revolut's backward-in-time pattern).

The shared loop handles initial-vs-continuation kwargs, cursor
extraction, cycle detection, nil-cursor stop, and a configurable safety
cap. New runtime token `{now_ms}` resolves to the current time in ms,
usable from `initial_kwargs`.

## 0.11.0 — Declarative `status_map`, `bank_code`, `field_aliases`

Three additive `config.yml`-driven knobs that lift orchestration
patterns out of per-provider Ruby:

- `Builder.map_status_from(raw, mapping)` — resolve a provider status
  code through a declared map; `posted`/`pending` canonicalize to the
  `Canonical::Transaction` constants, anything else passes through.
- `Builder.spanish_iban_portable_keys(iban, bank_code:)` and
  `Builder.card_pan_portable_keys(pan, bank_code:)` — own the
  `BANK:LAST4` portable-key shape so Spanish-bank providers only declare
  `bank_code` in `config.yml`. `Helpers.pan_last4` is now reachable as a
  module function so the Builder defers to one implementation.
- `Helpers#pick(logical_key, source)` — walk the `FIELD_ALIASES` alias
  chain auto-bound from `config.yml`'s `field_aliases:` block (`||`
  semantics; only `nil` counts as missing), replacing per-normalizer
  inline alias chains.

## 0.10.1 — Bare `application/json` on `json_post`

`json_post` now sends `Content-Type: application/json` without the
`;charset=UTF-8` suffix. ING's `/v2/products/transactions/search`
returns HTTP 200 with an empty `transactions: []` body — silently — when
the charset suffix is present; without it the same request succeeds.
`application/json` is implicitly UTF-8 per RFC 8259 §11, so the suffix
was never spec-correct. Now matches `raw_request`, which always used the
bare media type.

## 0.10.0 — `define_post` supports `json:` bodies

`define_post` gains a `json:` keyword (mutually exclusive with `form:`)
that serializes the body via `JSON.generate` with
`Content-Type: application/json`, for APIs whose payloads carry array or
nested fields that `URI.encode_www_form` would stringify lossily (e.g.
ING's search needs `uuids: [...]`). Templates (`{name}`, `{name|date}`,
`{name|iso}`, `{offset}`) interpolate identically in either shape, and
the pagination engine resolves `{offset}` inside JSON bodies the same
way it does for query params. Wired through workflow YAML with a `json:`
key on POST endpoints, validated mutually exclusive with `form:` at
schema-load time.

## 0.9.0 — Inline credentials over an fd, not a tmpfs dotenv

The `/invoke` inline-credentials path no longer materializes a tmpfs
dotenv consumed through the `plain_file` backend (which emitted an
INSECURE banner that bubbled up to the caller's UI with no operator
action available). A new `inline_fd` secret backend reads the dotenv
from an inherited fd (3) and never touches disk. Removes the tmpfs
scaffolding entirely (`@tmpfs_dir`, `cleanup_tmpfs`, the `/dev/shm`
sweep on server start, `FREENTONIC_TMPFS_DIR`, `--tmpfs-dir`). The
`plain_file` + `--secrets-file` path and its banner are unchanged.

## 0.8.0 — Configurable Xvfb / Chrome display geometry

The container's virtual-display geometry is configurable via
`FREENTONIC_XVFB_GEOMETRY` (default `1280x800x24`) instead of a
hard-coded resolution, with `DisplayGeometry` as the single source of
truth shared by the entrypoint's `Xvfb` launch and Chrome's window
sizing — so the VNC-observable viewport can match the operator's screen.

## 0.7.0 — Server-mode interactive prompts + per-host auth headers

### Server-mode interactive prompts (2FA / SMS)

Workflows that previously required a controlling TTY for 2FA — both
`prompt_stdin_and_fill` (SMS / OTP entry) and `pause` (manual approval
of a push notification) — now work in server mode. The same workflow
YAML works in CLI and server with no changes.

When stdin is not a TTY but the runner subprocess has
`FREENTONIC_RUN_DIR` set (which the invoke server always populates),
the runner writes a request file under `<run_dir>/prompts/` and
blocks polling for a response. HTTP clients of the invoke server
fulfill the prompt out-of-band via two new endpoints:

- `GET  /runs/{run_id}/prompts` — list pending prompts for a run
- `POST /runs/{run_id}/prompts/{prompt_id}` — submit the value
  (`{"value":"123456"}` for SMS code entry, `{}` for pause approval)

Single-use, per-prompt expiry, bearer-token auth, atomic file rename
on response writes, and the existing `realpath` escape guard apply.
The prompt value never appears in any log; the runner emits a
`[freentonic][prompt] {…json…}` advisory marker on stderr (no value)
so humans tailing `/runs/{run_id}/log` see why the run paused.

See `docs/invoke-server-api.md` for full API reference.

### Per-host auth headers + `|iso` date filter + `derived_credentials` Hash-pluck

Three additive features unblock fully-declarative YAML for providers that
talk to two hosts with different auth scopes (e.g. ING's legacy
cookie host + the v2 Bearer host on `api.ing.ingdirect.es`).

#### `derived_credentials` Hash-pluck (`key:`) form

`derived_credentials:` gains a second extraction mode alongside the
existing `regex:` + `capture:`. The new `key:` form plucks a single
key out of a Hash source — the natural shape of credentials produced
by `capture_outbound_request_headers`, which always emits a Hash
keyed by header name. Source not a Hash, or key missing, yields nil
(symmetric with the regex branch's "no match → nil" behavior).
Exactly one of `regex:` / `key:` must be set per entry — both or
neither raises a clear workflow validation error.

```yaml
derived_credentials:
  genoma_session_id:
    from: cookie
    regex: 'genoma-session-id=([^;]+)'
    capture: 1
  ing_api_authorization:
    from: ing_api_headers
    key:  Authorization
```

The regex branch additionally gains an explicit `is_a?(String)` type
guard, symmetric with the Hash type check in the new branch; this
was previously implicit (regex matching on a non-String would have
raised).


#### Per-host `auth_header`

`auth_header` and `update_auth_headers!` gain a `host:` kwarg. A
declaration scoped to a host only attaches to requests whose URL has
that host; unscoped declarations continue to apply to every host
(back-compat). Resolution order: unscoped declarations, then
host-scoped declarations, then unscoped overrides, then host-scoped
overrides — later passes win on a name collision; nil values omit the
header.

```ruby
class IngClient < Freentonic::ApiClient
  base_url "https://ing.ingdirect.es"
  auth_header "Cookie", from: :cookie                                  # all hosts
  auth_header "Authorization", host: "api.ing.ingdirect.es", from: :bearer
end

client.update_auth_headers!({ "Authorization" => "Bearer …" },
                            host: "api.ing.ingdirect.es")
```

YAML accepts both the existing flat-Hash form and a new
Array-of-host-blocks form:

```yaml
api_client:
  auth_headers:
    - headers:
        Cookie: "{cookie}"
    - host: "api.ing.ingdirect.es"
      headers:
        Authorization: "{bearer}"
        X-ING-ExtendedSessionContext: "{esc}"
```

`request` and `raw_request` now resolve headers against the actual
request URL via the new `auth_headers_for(url)` instance method;
`auth_headers` is preserved as a back-compat alias that returns
unscoped declarations + unscoped overrides.

#### `{name|iso}` interpolation filter

`ep_interpolate_val` gains an `|iso` branch that formats `Date`,
`DateTime`, or `String` values as `yyyy-mm-dd`, regardless of the
workflow's `date_format:`. Useful for endpoints that want ISO dates in
a workflow that otherwise uses a locale-specific format (e.g. ING's
legacy `dd/mm/yyyy` + v2 ISO).

```yaml
params:
  fromDate: "{from_date|date}"   # uses workflow date_format
  toDate:   "{to_date|iso}"      # always yyyy-mm-dd
```

## 0.6.0 — LegacyKeys removed; canonical-only payloads

The receiver-side transition window has closed (verified against
finanzas-web). All legacy-compatibility infrastructure is gone:
`Freentonic::Providers::LegacyKeys`, the per-provider `legacy.yml`
loader, and the `legacy_external_id` / `legacy_uids` / `legacy_bank_key` /
`legacy_dedup_key` kwargs on `CanonicalBuilder.build_account` and
`build_transaction`. Account and transaction metadata no longer carries
any `legacy_*` keys.

### Removed

- `Freentonic::Providers::LegacyKeys` and `LegacyKeysLoader` modules
  (~260 LoC + their two test files).
- `Freentonic::Providers::CanonicalBuilder.account_legacy_metadata` and
  `transaction_legacy_metadata` helpers.
- `legacy_external_id:` / `legacy_uids:` / `legacy_bank_key:` kwargs
  from `CanonicalBuilder.build_account`.
- `legacy_dedup_key:` kwarg from `CanonicalBuilder.build_transaction`.
- `LegacyKeys` constant alias from `Freentonic::Providers::NormalizerBase`.
- `legacy.yml` loading from `Configurable#provider!` — the macro now
  loads only `config.yml`.

### Migration for provider authors

1. Drop `**LegacyKeys.account(...)` / `**LegacyKeys.transaction(...)`
   splats from `Builder.build_account` / `Builder.build_transaction`
   call sites.
2. Delete the per-provider `legacy.yml` file.
3. Drop any test assertions on `metadata["legacy_external_id"]`,
   `metadata["legacy_uids"]`, `metadata["legacy_bank_key"]`,
   `metadata["legacy_dedup_key"]`.

The deterministic `acc_…` / `txn_…` IDs from the canonical helpers
(`Canonical.account_id`, `Canonical.transaction_id`) are unchanged —
that's the only join key receivers should be using.

## 0.5.0 — Formatter layer removed; exporters render canonical directly

The `Freentonic::Formatters` module introduced in 0.2.0 is gone.
Exporters now render the canonical payload into their wire shape
themselves. SimpleFIN, OFX, and other third-party interchange formats
are explicitly out of scope for freentonic — adapt the canonical model
in downstream consumers instead.

### Removed

- `Freentonic::Formatters` module and all four classes (`Base`,
  `Canonical`, `CsvTransactions`, `JsonlTransactions`).
- `--export-format NAME` CLI flag. The `csv`, `jsonl`, `json`, and
  `http` exporters each have one fixed wire shape; there is nothing to
  pick.
- `Exporters::Base#resolve_formatter` and `#default_format`.
- `docs/formatters.md` and `docs/canonical-migration-plan.md`.

### Changed

- `csv` exporter: row-shaping logic (header sort, account_* hoisting,
  JSON-stringified nested cells) moved inline. Behavior unchanged.
- `jsonl` exporter: NDJSON shaping logic moved inline. Behavior
  unchanged.
- `json` exporter: writes `payload.to_h` as pretty JSON. Plain Hash
  inputs still pass through (`Hash#to_h` returns self).
- `http` exporter: POSTs `payload.to_h` as JSON. `Content-Type` is
  `application/json` unless `--export-content-type` overrides. The
  `meta.freentonic_run_id` merge behavior is unchanged.
- `docs/canonical-data-model.md`, `docs/writing-plugins.md` — updated
  to drop the Formatter-layer narrative.

### Migration

- Drop `--export-format` from any invocation; the exporter's wire shape
  is now fixed. `--export-content-type` still exists for the http
  exporter.
- If you registered a custom formatter via `Formatters.register`, port
  the rendering logic into a custom exporter (`Exporters.register`)
  instead.

## 0.4.0 — Provider boilerplate absorbed into the gem

Several additive changes whose combined effect is to drop the
per-provider Ruby boilerplate to almost nothing. Fully backward
compatible; safe drop-in upgrade from 0.3.0.

### Added

- `Freentonic::Providers::Config` — declarative loader for per-provider
  `config.yml` files. Same YAML safe-load hardening as
  `LegacyKeysLoader` (`permitted_classes: []`, `aliases: false`) —
  refuses `!ruby/object:` tags, YAML aliases, and anything that would
  deserialize into a Ruby object. Top-level keys are symbolized; inner
  hash key types are preserved (so lookup tables keyed on upstream
  strings or integers still work without a `transform_keys` round-trip).
  Caches per institution by directory basename. Optional per provider:
  missing `config.yml` returns `nil`.

- `Freentonic::Providers::NormalizerBase` — base class for provider
  normalizers that absorbs every line of header boilerplate. Inherits
  `Freentonic::Normalizers::Base`, includes
  `Freentonic::Providers::Helpers` automatically, and defines class
  constants `Builder` + `LegacyKeys` aliasing the gem's
  `CanonicalBuilder` + `LegacyKeys`. A class macro
  `provider!(dir)` loads `<dir>/legacy.yml` and `<dir>/config.yml`,
  defines `CONFIG`, and auto-generates an UPCASE class constant for
  every top-level key in the config. The macro is additive — explicit
  constant assignments in the subclass take precedence over macro
  auto-definitions.

  A provider's normalizer header now collapses from 10–15 lines to ~3:

  ```ruby
  require "freentonic"
  module Freentonic::Providers::Fintonic
    class Normalizer < Freentonic::Providers::NormalizerBase
      provider!(__dir__)
      # CONFIG, INSTITUTION, SCRAPER_VERSION, KIND_BY_TYPE all defined.
      # Builder, LegacyKeys, Helpers all inherited.
    end
  end
  ```

- `Freentonic::Providers::ExtractorBase` — mirror of `NormalizerBase`
  for provider extractors. Includes `Helpers`, extends `Configurable`
  (shares the `provider!(dir)` macro). Intentionally NOT a subclass of
  any framework abstract class — extractors are duck-typed by the
  Extract stage. Gives every provider extractor the same shape:

  ```ruby
  class Extractor < Freentonic::Providers::ExtractorBase
    provider!(__dir__)
    def call(client:, credentials:, from_date:, stdout:, stderr:)
      # provider-specific fetch logic
    end
  end
  ```

- `Freentonic::Providers::Configurable` — mixin that carries the
  `provider!(dir)` macro. Both `NormalizerBase` and `ExtractorBase`
  extend it so the macro lives in one place.

- `Freentonic::Providers::Helpers#extract_fields(source, mapping)` —
  declarative source-to-hash projection for raw-payload allowlists.
  Mapping value may be a String (simple rename / dotted-path nested
  lookup like `"status.description"`) or an Array of Strings (fallback
  chain — first non-nil wins). Output keys always stringified; missing
  paths yield `nil` entries to keep column sets stable across syncs.

- `Freentonic::Providers::Helpers#first_present(*candidates)` —
  returns the first candidate that's a non-empty stripped string, or
  `nil`. Replaces ad-hoc `pick_name`-style private methods that were
  reimplemented across providers.

### Fixed

- `--through connect` and `--through extract` no longer reject runs
  without `--export NAME`. The `--only-stage connect` / `extract`
  variants were already exempted from the "no exporters configured"
  validator (the pipeline stops before Export, so an exporter is
  meaningless), but `--through` was rejected — forcing devs to use
  `--only-stage` as a workaround when iterating on a login or
  extraction step. Both flags now behave symmetrically.

### Test suite

477 runs / 1185 assertions / 0 failures (was 437/1110). 11 Config
loader tests + 7 NormalizerBase tests + 4 ExtractorBase tests + 4 CLI
validation tests + 8 extract_fields tests + 5 first_present tests +
3 parse_date `preferred_formats:` tests.

### Migration notes for provider authors

Existing 0.3.x-style provider normalizers continue to work unchanged.
To pick up the new boilerplate-collapse:

1. Inherit from `Freentonic::Providers::NormalizerBase` instead of
   `Freentonic::Normalizers::Base` (or `Freentonic::Providers::ExtractorBase`
   for extractors — no prior base class was required).
2. Replace the existing `LegacyKeysLoader.load_provider!(__dir__)`
   call (and any `Config.load_provider!`) with a single
   `provider!(__dir__)` macro call inside the class body.
3. Drop `include Freentonic::Providers::Helpers`,
   `Builder = ...`, and `LegacyKeys = ...` aliases (inherited now).
4. Move `INSTITUTION` / `SCRAPER_VERSION` / lookup tables / date-format
   hints / magic strings / raw-payload field allowlists to
   `<provider>/config.yml`; the macro will auto-define them as
   class constants with UPCASE names.
5. Where an inline `rescue StandardError; stderr.puts …; = default`
   pattern exists, replace with `safe_fetch(stderr, "label") { … } || default`.
6. Where a bespoke `pick_name(*candidates)` private method exists,
   replace call sites with `first_present(*candidates)` and delete
   the private method.

## 0.3.0 — Provider-authoring library absorbed

Pulls the shared `Freentonic::Providers` namespace into the gem so
provider repos (like `freentonic-providers`) no longer need to
co-locate it under their own `lib/`. Nothing in this release changes
the runtime behavior of the existing pipeline; downstream consumers
on 0.2.0 who don't author providers can upgrade for free.

### Added

- `Freentonic::Providers::CanonicalBuilder` — helper for building
  `Canonical::Account` / `Canonical::Transaction` / `Canonical::Liability`
  entities with legacy-compat metadata merged onto caller-supplied
  metadata (legacy keys win, so providers can't accidentally blank
  them out).
- `Freentonic::Providers::Helpers` — `safe_fetch`, `cents` (with
  `already_minor:` kwarg), `parse_date` (now with `preferred_formats:`
  kwarg — see Changed), `parse_timestamp_ms`. Include the module in
  a provider class to pick up the whole set.
- `Freentonic::Providers::LegacyKeys` — declarative registry for
  per-provider legacy-compat metadata (legacy_external_id, legacy_uids,
  legacy_bank_key, legacy_dedup_key). Accepts only String templates,
  Array-of-Strings, and Hash-with-`default:`/`if_<value>:` branches;
  rejects Proc / Symbol / unknown hash keys at register time with
  `InvalidConfigError`. Template substitution uses Ruby's native
  `String#%` with named placeholders.
- `Freentonic::Providers::LegacyKeysLoader` — YAML-based loader for
  per-provider `legacy.yml` files. Parses with
  `YAML.safe_load(permitted_classes: [], aliases: false)` so
  `!ruby/object:...` tags and YAML aliases cannot deserialize into
  Ruby objects. New `load_provider!(dir)` entrypoint for the common
  single-provider case; `load_all!(root:)` still available for bulk
  loading in tests or tooling.
- `Freentonic::Providers::Scaffold` — `rake new[provider]` template
  generator that emits a starter workflow/extractor/normalizer/test
  set. Authoring tool; lazy-required from Rakefiles (not auto-loaded
  by `require "freentonic"`).
- `Freentonic::Providers::HarAnalyzer` — `rake har[file]` investigation
  tool for turning a HAR capture into a workflow skeleton. Also an
  authoring tool; lazy-required.

### Changed

- `Helpers.parse_date` gains an optional `preferred_formats:` keyword
  argument — a list of strptime patterns to try first (in order) when
  the input is a non-timestamp String. Useful for locale-ambiguous
  formats: `parse_date("05/06/2024", preferred_formats: ["%d/%m/%Y"])`
  reliably yields 5 June (not 6 May as `Date.parse` would). Non-matching
  patterns are skipped silently; if every pattern misses, falls through
  to the generic `Date.parse` path. Fully backward compatible — callers
  that don't pass the kwarg see unchanged behavior.

### Test suite

437 runs / 1110 assertions / 0 failures. Adds `test/canonical_builder_test.rb`,
`test/helpers_test.rb`, `test/legacy_keys_test.rb`, and
`test/legacy_keys_loader_test.rb` from the sibling providers repo.

### Migration notes for provider authors

Before 0.3.0, provider repos carried their own `lib/freentonic/providers/`
directory with these classes. After 0.3.0:

- Drop the local `lib/freentonic/providers/*.rb` and the corresponding
  `lib/test/*_test.rb`.
- Replace `require_relative "../lib/freentonic/providers/X"` with
  `require "freentonic/providers/X"` — or just `require "freentonic"`
  to pick up the whole runtime set.
- For per-provider `legacy.yml` loading, switch
  `LegacyKeysLoader.load_all!` (which used to auto-discover from a
  co-located root) to `LegacyKeysLoader.load_provider!(__dir__)` at
  the top of each normalizer.

## 0.2.0 — Canonical data model

This release introduces the canonical internal data model as the Normalize
stage's output contract and a new Formatter layer that produces wire shapes
from it. See [docs/canonical-data-model.md](docs/canonical-data-model.md)
and [docs/canonical-migration-plan.md](docs/canonical-migration-plan.md)
for the full spec and the sequenced rollout.

### Added

- `Freentonic::Canonical` module — typed `CanonicalPayload` envelope
  (`schema_version`, `summary`, `meta`, `accounts`, `transactions`,
  `liabilities`, `investments`) with `Data.define` value objects per
  entity. `SCHEMA_VERSION = "0.1"`.
- Deterministic-ID helpers — `Canonical.transaction_id`,
  `Canonical.account_id`, `Canonical.liability_id`,
  `Canonical.investment_id`. SHA-256 truncated to 16 hex chars, prefixed
  (`txn_` / `acc_` / `liab_` / `inv_`). `Canonical.account_id` raises
  `UnstableIdError` when inputs cannot produce a stable ID.
- First-class `source_id` field on every entity for the raw bank-side
  reference (unique within a single source only — do NOT use for
  cross-source joins).
- Framework-computed `summary` on every `CanonicalPayload`: counts,
  `amounts_by_currency`, `balances_by_currency`, `date_range`,
  `generated_at`.
- `Freentonic::Formatters` registry — three built-ins: `:canonical`
  (identity), `:csv_transactions`, `:jsonl_transactions`. Formatters
  declare their own `content_type`.
- `--export-format NAME` CLI flag, universal across all exporters.
  Default per exporter: `http` and `json` emit `:canonical`; `csv`
  emits `:csv_transactions`; `jsonl` emits `:jsonl_transactions`.
- `docs/canonical-data-model.md`, `docs/formatters.md`, and
  `docs/canonical-migration-plan.md` — full spec, formatter-layer
  architecture, and six-step migration plan.
- `examples/extractor.rb`, `examples/normalizer.rb`,
  `examples/raw.example.json` — a working end-to-end reference
  implementation of a canonical-emitting provider; exercised by
  `test/example_workflow_integration_test.rb`.

### Changed

- Normalize stage output contract is now `CanonicalPayload`. The
  pre-existing `Normalizers::Passthrough` still works for workflows
  with no `normalize:` block, and the `http` / `json` exporters apply
  the `canonical` formatter as the identity on plain Hash payloads, so
  normalizers that still emit ad-hoc shapes continue to work — but new
  normalizers should return `CanonicalPayload` to get the full benefit
  (schema_version, summary, deterministic IDs).
- `http` exporter: `Content-Type` now comes from the selected
  formatter's `content_type` unless `--export-content-type` overrides
  it. Hash outputs get the `meta.freentonic_run_id` merge as before;
  String outputs (OFX, CSV, NDJSON) are shipped verbatim.
- `json` exporter: resolves a formatter (default `:canonical`),
  pretty-prints Hash/Array outputs, writes String outputs verbatim.
- `csv` / `jsonl` exporters: rewrote as thin wrappers around the
  `csv_transactions` / `jsonl_transactions` formatters. Each now
  **requires a `CanonicalPayload` input** and raises `UserError`
  pointing at the migration docs when handed a plain Hash.
- Money on the wire is now a JSON **string** (e.g. `"amount": "-45.20"`),
  internally `BigDecimal`. Matches industry convention and preserves
  exact precision across the wire. JavaScript consumers parse with a
  decimal library or `parseFloat`.
- `docs/writing-plugins.md` — normalizer section rewritten around the
  canonical contract; replaced the trivial Renaming example with a
  worked `MyBank::Normalizer` building canonical entities with the
  deterministic-ID helpers.

### Removed

- **`--export-csv-select PATH` CLI flag is removed.** Under the
  canonical model, slot names are fixed (`transactions`), so a generic
  select-path is no longer needed. Workflow authors who need
  alternative flattenings (e.g. one row per account) should write a
  new formatter.
- Corresponding `export.select` field on the invoke server JSON-RPC
  schema is removed (`app/controllers`-side callers must drop it).

### Migration notes for consumers

- HTTP receivers built against the pre-canonical ad-hoc normalizer
  shapes will need to either (a) accept the new canonical envelope, or
  (b) implement a receiver-side adapter that translates canonical into
  the legacy hash shape before ingestion. See the worked receiver
  adapter described in the sibling migration docs for the freentonic
  downstream consumer.
- Existing normalizers in the `freentonic-providers` sibling repo have
  been migrated to emit `CanonicalPayload` and ship legacy-compatibility
  metadata (`legacy_external_id`, `legacy_uids`, `legacy_bank_key` on
  accounts; `legacy_dedup_key` on transactions) during the cutover
  window, enabling receiver-side self-healing matching without a
  backfill rake task.

### Test suite

374 runs / 968 assertions / 0 failures. New coverage across
`test/canonical_*.rb`, `test/formatters_test.rb`,
`test/export_format_wiring_test.rb`, and
`test/example_workflow_integration_test.rb` exercises the full
Connect-less pipeline end-to-end.
