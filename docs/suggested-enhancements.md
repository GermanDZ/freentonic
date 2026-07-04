# Architecture & Security Review — Suggested Enhancements

Full-codebase review of freentonic v0.12.0 (commit 072a431): pipeline core,
browser workflow runner, API client, canonical model, secrets, exporters,
invoke server, and Docker deployment. Three parallel deep-dives (core
security audit, architecture review, server/deployment review) synthesized
into one prioritized list.

## What freentonic is (reviewer's summary)

A zero-runtime-dependency Ruby gem that turns a single YAML file plus a
small amount of provider Ruby into a full bank-data pipeline:

- **connect** — drives real Chrome over CDP through a declarative login
  pipeline (~33 workflow actions), captures cookies/headers/tokens.
- **extract** — builds an HTTP client dynamically from `api_client:` YAML
  (auth headers, host scoping, derived credentials, offset + cursor
  pagination) and runs a small provider extractor.
- **normalize** — provider normalizer → frozen canonical entities with
  deterministic SHA-256 IDs (`SCHEMA_VERSION 0.1`).
- **export** — fan-out to json/jsonl/csv/http, registry-pluggable.

Two operating modes: CLI (with `--dump-raw`/`--from-raw` offline
iteration — the killer feature) and a hand-rolled stdlib HTTP invoke
server for automation, with file-rendezvous remote prompts for 2FA/OTP
and `await_external_approval`.

## Overall verdict

**The security posture is unusually disciplined for a project this size,
and every invariant claimed in SECURITY.md holds in code.** Verified:

| SECURITY.md invariant | Verdict | Evidence |
| --- | --- | --- |
| YAML `safe_load(permitted_classes: [], aliases: false)` | HOLDS | `workflow_schema.rb:14`; only other YAML load (`providers/config.rb:86-90`) equally safe |
| JS args always via `JSON.generate` | HOLDS | `browser_workflow_runner.rb:1216,1229-1234,1021-1029`; `fill` is *stronger* — CDP key events, value never enters JS (`:754-765`) |
| `Process.spawn` array form only | HOLDS | `chrome_cdp.rb:221`, `invoke_runner.rb:252-254` (`unsetenv_others: true`); no backticks/shell strings in `lib/` |
| `api_client.ext` strict `const_get(name, false)` walk | HOLDS | `workflow_schema.rb:202-212` |
| HTTP exporter token env fallback | HOLDS | `exporters/http.rb`; server keeps token off argv (`invoke_runner.rb:237-240`) |
| `prompt_stdin_and_fill` never persisted/logged | HOLDS (tty); remote path has documented sub-second 0600 on-disk window, then redacted (`remote_prompt_store.rb:196-203`) |
| record/dump_requests caps + allowlisted dumps | HOLDS | `workflow_schema.rb:350-377`, `engine.rb:84-95` |

Strengths worth actively preserving: CDP key-event typing for `fill`;
0600 + atomic-write discipline (screenshots, recordings, prompts, run
logs); inline credentials over an anonymous pipe fd, never disk/argv/env;
single-use prompt semantics via `File.link` create-if-absent; recorder
probe masking password/otp/cvv fields in-page; host-scoped auth headers;
timing-safe token compare; realpath escape guards on every
filesystem-derived server route; the engine's explicit `:raw`/`:normalized`
dump allowlist; strict HTTP request framing (Transfer-Encoding rejected,
Connection: close everywhere).

No confirmed-exploitable framework defect was found. The highest-impact
property — a workflow YAML can exfiltrate captured credentials anywhere —
is the documented trust model ("YAML is code"), honestly stated in
SECURITY.md. Everything below is hardening and architecture leverage.

---

## P0 — Small diffs, do first

### 1. `run_id` / `profile_key` accept `"."` and `".."` — containment escape on the write path
`RUN_ID_PATTERN` and `PROFILE_KEY_PATTERN` (`invoke_request.rb:32-33`)
admit the literal strings `.` and `..`. The read endpoints and prune are
saved by realpath guards, but `InvokeRunner#run` is not:
`File.join(@runs_dir, request.run_id)` (`invoke_runner.rb:98`) with
`run_id=".."` resolves to the workspace root — truncates `/workspace/log`,
creates a stray `prompts/` dir, and `collect_artifacts`
(`invoke_runner.rb:334-342`) globs **every run of every tenant** into the
response. Same shape for `profile_key=".."` on the Chrome profile root
(`invoke_runner.rb:105`). Requires a valid bearer token, but it breaks the
containment the rest of the code works hard for.

**Fix:** reject `.`/`..` in both patterns (require a leading alnum) and add
an expand_path prefix check in `InvokeRunner#run` as defense in depth.
Add tests — `invoke_runner_test.rb` never tries dot-only ids.

### 2. `dump_requests` files are written with default umask, not 0600
`debug_request_writer.rb:68-73,87` uses plain `File.open(..., "w")` /
`File.write` — these files contain raw request headers, session cookies,
and response bodies, yet land world-readable (0644 under a typical umask)
while screenshots, recordings, and prompt files are all explicitly 0600.

**Fix:** open with `File::WRONLY | File::CREAT | File::TRUNC, 0o600` to
match the rest of the codebase's secret-file discipline.

### 3. No graceful shutdown drain — and the docs claim there is one
`InvokeServer#shutdown` only flips a flag and closes the listener
(`invoke_server.rb:122-126`); `bin/freentonic-server:55` then falls off the
end, killing the handler thread mid-`Process.wait2`. tini runs without
`-g` (`Dockerfile:82`), so the in-flight freentonic/Chrome child gets no
SIGTERM — it dies by container-teardown SIGKILL, risking Chrome-profile
corruption and losing the blocked `/invoke` response.
`docs/invoke-server-deployment.md:220-226` says the server "waits for the
in-flight invoke to finish"; the code does not join anything.

**Fix:** on shutdown, stop accepting, SIGTERM the in-flight process group,
join handlers with a bound; or at minimum switch to `tini -g`, correct the
doc, and document `docker stop -t` sized to `timeout_sec`.

### 4. Prompt-store edge cases can strand an OTP on disk
`handle_submit_prompt` accepts a POST for a run that is **not in flight**
(only expiry is checked, `invoke_server.rb:704-733`). If the child crashed
after writing a prompt request, the OTP-bearing `response.json` is written
and never consumed or redacted — it sits on the host-bind-mounted runs dir
until external retention deletes it. Also, `handle_list_prompts`
(`invoke_server.rb:672-696`) does not filter expired prompts, so dead
cards linger in client UIs.

**Fix:** reject prompt submissions when `run_id` is not in `@in_flight`;
skip expired entries in the list.

### 5. Three error-handling holes turn user mistakes into raw backtraces
- ~20 workflow actions use `step.fetch(...)` at runtime (`navigate`,
  `wait`, `wait_url`, `click`, …); `KeyError` is not a `RuntimeError`, so
  Connect's `rescue RuntimeError` (`stages/connect.rb:55-56`) misses it and
  the CLI (which rescues only `UserError`/`ExportError`, `cli.rb:33-38`)
  shows a raw backtrace — possibly *after* the operator completed 2FA.
- `Engine#load_serialized_inputs!` (`engine.rb:76-82`): malformed
  `--from-raw` JSON raises uncaught `JSON::ParserError`.
- Connect's blanket `rescue RuntimeError` also swallows genuine framework
  bugs — `chrome_cdp.rb` raises bare `RuntimeError` strings
  (`:383,440,446`) — and `ApiClient::SessionExpired` escapes Extract
  uncaught unless the provider rescues it.

**Fix:** typed `ChromeCdp::Error`; wrap the JSON parse in `UserError`;
rescue `SessionExpired` in Extract with an actionable message. (Load-time
validation in P1 removes the `KeyError` class entirely.)

### 6. Documentation drift (pure doc fixes)
- `docker-run-freentonic.sh:75` and `docs/invoke-server-deployment.md:357`
  still say the VNC password is hard-coded to `freentonic`; the actual
  design rotates a per-invoke password and relocks on exit
  (`invoke_runner.rb:117-166`). Operators following the doc will fail.
- The API doc's prompt-kind list (`docs/invoke-server-api.md:447-455`)
  omits `await` — the headline new feature.
- CHANGELOG.md stops at 0.7.0 + one Unreleased entry while
  `version.rb` says 0.12.0; git tags stop at v0.8.0. With providers in a
  separate repo, the YAML dialect **is** the public API and the changelog
  is its only version signal. Backfill 0.8–0.12 and tag.

---

## P1 — High-leverage improvements

### 7. Action registry + exhaustive load-time validation (the single biggest core win)
`browser_workflow_runner.rb` (1,540 lines) holds a 33-branch `case`
dispatch (`:66-262`), all JS payloads, SCA orchestration, recording, and
prompting. Meanwhile `workflow_schema.rb` validates only ~13 of the ~33
actions and has **no unknown-action check** — a typo like `navigat` passes
validation and dies mid-run at the runner's `else` branch (`:261`).

**Fix:** a declarative action table —
`Action.register("navigate", required: {url: :string}, ...) { |step, ctx| ... }` —
driving (a) dispatch, (b) schema validation for *all* actions at load
time (unknown action + required keys), and (c) generated docs (the 27
`docs/workflow-action-*.md` pages could be emitted from the table, ending
the three-parallel-structures problem). Provider authors get validation
errors in milliseconds instead of failed 2FA runs. Effort ~1–2 days;
directly serves the "minimize provider friction" priority.

### 8. `freentonic --lint` dry-run (cheap once #7 lands)
Load the schema, resolve `extract:`/`normalize:` files and classes, build
the ApiClient class, check `credentials.require/map` keys against the
capture actions' `as:` outputs, and verify every `secret()` token has a
`secrets:` declaration — everything except Chrome. Today the earliest full
check of a workflow is a live bank login. All the pieces exist; they just
need invoking without side effects. Note `extract:`/`normalize:`/
`credentials:` specs are currently validated only when their stage runs
(`stages/extract.rb:89-91`, `stages/normalize.rb:30-32`, `source.rb:46-48`).

### 9. Close the pre-auth slow-drip DoS on the invoke server
`BufferedReader#fill_buffer` resets its 30 s `IO.select` window on every
byte (`invoke_server.rb:294-309`); a client trickling 1 byte/29 s holds
one of the 64 global connection slots indefinitely, without a token. 64
such sockets 503 everything including `/healthz`. Loopback binding limits
exposure, but it's the one DoS hole in an otherwise well-limited surface.

**Fix:** absolute wall-clock deadline from accept to end-of-headers
(e.g. 30 s), and/or a smaller pre-auth connection budget.

### 10. Confine server-supplied paths
- `credentials.file` accepts any absolute path in the container
  (`invoke_request.rb:180-187`); it is fed to the child as
  `--secrets plain_file` and its content hash becomes the derived
  `profile_key` visible via `/status` — a content-confirmation oracle for
  any readable file. Require it under a configured secrets root with the
  same expand_path/realpath treatment workflows already get
  (`invoke_request.rb:111-140`).
- `extract.ruby` / `api_client.ext.file` accept absolute paths
  (`stages/extract.rb:95-97`, `workflow_schema.rb:202-212`). Workflows are
  trusted code by design, but confining these to the workflow's own
  directory subtree is cheap and shrinks the residual chain (a
  token-holder can name export output `foo.rb` inside the writable run
  dir via `export.path`, `invoke_request.rb:261-267`).

### 11. CSV formula-injection guard
`exporters/csv.rb:60-68` writes transaction fields straight through.
Merchant names / transfer memos are attacker-influenceable text from the
bank; `=HYPERLINK(...)`, `@SUM(...)` etc. execute when the CSV is opened
in Excel/Sheets. Prefix cell values starting with `= + - @ \t \r` with a
leading apostrophe.

### 12. Refuse (or loudly warn on) cleartext HTTP export with a token
`exporters/http.rb` sets `use_ssl` only for `https://` URLs; an `http://`
`--export-url` sends the full financial payload plus the bearer token in
cleartext with no warning. TLS verification itself is fine (implicit
`VERIFY_PEER`) and redirects are not followed (good — a 30x can't forward
the token). Related foot-gun: `resolved()` runs `secret(...)` substitution
on `note`/`navigate` strings (`browser_workflow_runner.rb:78,89`), so a
YAML author can accidentally print a resolved secret into the run log —
skip resolution for `note`, or document the hazard.

---

## P2 — Architecture evolution

### 13. Async `/invoke` (202 + poll) — highest-leverage server change
A synchronous HTTP call that can block up to 2 hours forces huge client
read-timeouts, is fragile through proxies, and couples the DoS surface to
run duration. A client that disconnects mid-run does **not** cancel the
run (`write_response` swallows EPIPE, `invoke_server.rb:374-375`) — the
bank login proceeds for nobody. Prompts, log Range-polling, and cancel are
already async-shaped; `/invoke` is the outlier. Return
`202 {run_id}` + `GET /runs/:id` status; existing endpoints unchanged.
When parallelism follows, note the current safety property — one global
mutex covers `/invoke` and `/profiles/prune` — must become a
per-`profile_key` mutex that still covers prune and Chrome cleanup.

### 14. Structured run events + minimal observability
Everything logs via `stdout.puts "  [yml] ..."`, and the server already
parses one magic stderr line (`[freentonic][prompt] {…}`) — a structured
channel begging to be generalized. Add a small `Reporter`
(event, phase, step, elapsed_ms) with the human formatter as default and
NDJSON when `FREENTONIC_RUN_DIR` is set. On the server: one access-log
line per request (method, path, status, ms — no bodies), a
`queued`/`running` distinction in `/status` (in-flight registration
currently happens before the mutex, so `elapsed_ms` includes queue wait,
`invoke_server.rb:439-450`), and run-count/duration/error_kind metrics.

### 15. Container hardening + token lifecycle
- Document/apply in the wrapper: `--security-opt no-new-privileges`,
  `--cap-drop ALL`, read-only rootfs with tmpfs for `/dev/shm` and `/tmp`.
  Chrome runs `--no-sandbox` unconditionally (`invoke_runner.rb:211`); a
  compromised renderer can read all tenants' profiles and run artifacts
  under the shared uid. Longer-term, evaluate Chromium's user-namespace
  sandbox in-container (test against the ING-verified anti-detection
  flags before changing anything).
- `FREENTONIC_INVOKE_TOKEN_FILE` (the token currently arrives via `-e`,
  visible in `docker inspect`) and accept a set of tokens so rotation
  doesn't require simultaneous client cutover.

### 16. Retire the cheapest untested risk
No dedicated tests for: `engine.rb` (the `only`/`through`/`from_raw`
skip matrix — pure logic), `stages/connect.rb` (520 lines, three modes),
export fan-out partial-failure semantics (`stages/export.rb:22-33` runs
all exporters then re-raises `errors.first` — documented behavior with no
test pinning it), `Source#extract_credentials`, and `chrome_cdp.rb`'s
pure functions (cookie helpers, WS framing). Plus the P0 gaps: dot-only
ids, shutdown drain, submit-prompt for a not-in-flight run, and `await`
end-to-end through the HTTP layer (only the store's `until_satisfied` is
tested today).

---

## P3 — Direction

### 17. Declarative extractor plan — the next step toward zero provider Ruby
v0.11/v0.12 (status_map, field_aliases, bank_code, cursor pagination)
removed the hard parts; most remaining extractor Ruby is orchestration
shape: "call endpoint A, for each account call endpoint B, assemble
`{accounts:, transactions:}`". An `extract: plan:` YAML form
(fetch → for_each → collect) with the Ruby-class escape hatch preserved
would take trivial providers to zero extractor LoC — the stated priority.

### 18. Export resilience
One retry with backoff in the http exporter on
`Net::OpenTimeout`/`ECONNREFUSED`/5xx — a failed push costs a whole bank
login to redo. Export stage: aggregate error naming *all* failed
exporters instead of `errors.first`. Also move the http exporter's
progress output off global `$stdout` (`exporters/http.rb:82`) onto the
injected stream like everything else.

### 19. Plugin/registry unification
`Exporters.build(name, options = {})` vs `Secrets.build(name, **opts)`;
the CLI special-cases `plain_file`/`inline_fd` construction
(`cli.rb:277-287`), so a third-party secret backend that needs options
can't receive them. Route options through the registry uniformly.

### 20. Internal `api_client.rb` split (mechanical)
909 lines, four concerns; the `ep_` prefix (`api_client.rb:674-905`) is
namespace-by-prefix for a missing module split. Extract `Interpolation`
and `CursorPagination` modules; unify `ep_parse_timestamp_ms` with
`Helpers.parse_timestamp_ms` (duplication acknowledged in a comment at
`api_client.rb:861`). Similarly, `Source#extract_spec` reaches into
`workflow.instance_variable_get(:@raw)` (`source.rb:41`) and the
extract-spec lookup is defined in two places (`stages/extract.rb:88`).

### 21. Workflow schema versioning policy
Document what `version: 1` promises: additive keys never bump; renames
bump to `version: 2` with a one-release dual-accept window. Pairs with
the changelog repair in P0 #6 — provider authors need a stable contract
they can pin against.
