# Enhancements Tracking

Tracks planning and implementation status for each item in
[`suggested-enhancements.md`](suggested-enhancements.md). Update the
**Status** column as work progresses; add dated notes under the relevant
item when a decision is made, a PR opens, or scope changes.

Status values: `Not started` · `Planned` · `In progress` · `Blocked` ·
`Done` · `Won't fix` (with reason).

## P0 — Small diffs, do first

| # | Item | Status | PR / Commit | Notes |
| - | --- | --- | --- | --- |
| 1 | `run_id`/`profile_key` accept `.`/`..` — containment escape | Done | 53de917 | Leading-alnum patterns + `ensure_contained!` defense-in-depth in `InvokeRunner#run`; dot-id tests added |
| 2 | `dump_requests` files not written 0600 | Done | 6d19466 | Both ndjson + har writers open `WRONLY\|CREAT\|TRUNC, 0600`; mode tests added |
| 3 | No graceful shutdown drain (docs overstate it) | Done | 68db2a3 | Server SIGTERMs in-flight child pgroup + joins handlers ≤20s; deployment doc corrected (`docker stop -t`) |
| 4 | Prompt-store edge cases can strand an OTP on disk | Done | cc9c469 | Reject submit when run not in `@in_flight`; skip expired prompts in list |
| 5 | Error-handling holes → raw backtraces (KeyError, JSON parse, SessionExpired) | Done | 0264743 | Typed `ChromeCdp::Error`; Connect rescues `ChromeCdp::Error, KeyError`; `--from-raw`/`--from-normalized` JSON wrapped in `UserError`; `SessionExpired` rescued in Extract |
| 6 | Documentation drift (VNC password, `await` kind, changelog gap) | Done | 2b102a2 | VNC per-invoke password doc fix; `await` kind documented; CHANGELOG backfilled 0.8–0.12; tags v0.5–v0.12 created (local) |

## P1 — High-leverage improvements

| # | Item | Status | PR / Commit | Notes |
| - | --- | --- | --- | --- |
| 7 | Action registry + exhaustive load-time validation | Done | p1-action-registry | `WorkflowActions` registry: single source of truth for action names + required keys. Load-time unknown-action check + required-key validation for all ~33 actions; drift-guard test locks registry ⇔ runner dispatch. Runner dispatch not yet driven from the table (kept as-is, guarded); doc-generation from the table remains a follow-up |
| 8 | `freentonic --lint` dry-run | Done | p1-action-registry | `Linter` + `--lint` flag: schema/action validation, extract/normalize/ext ruby + class resolution, api_client class build, credentials.require ⇔ capture as: cross-ref, secret() ⇔ secrets: cross-ref. No Chrome, no network. Exit 0 clean / 1 on error |
| 9 | Close pre-auth slow-drip DoS on invoke server | Done | p1-improvements | `REQUEST_READ_DEADLINE` (30s) — absolute accept→end-of-body budget in `BufferedReader`, enforced per `IO.select` via a monotonic deadline so a 1-byte/29s drip can no longer pin a slot. Direct BufferedReader tests |
| 10 | Confine server-supplied paths (`credentials.file`, `extract.ruby`/`ext.file`) | Done | p1-improvements | Part 1: `credentials.file` resolved under a secrets root (`--secrets-dir`/`FREENTONIC_SECRETS_DIR`, default `/workspace/secrets`) with re-root + realpath containment — closes the /status content-oracle. Part 2: `PathConfinement.resolve_within!` locks `extract.ruby`/`normalize.ruby`/`api_client.ext.file` to the workflow's directory subtree (rejects `../`, absolute, symlink escapes); enforced at runtime + in `--lint` |
| 11 | CSV formula-injection guard | Done | p1-improvements | `neutralize_formula` prefixes `'` on cells starting with `= + - @ \t \r`; skips plain numeric literals so negative amounts stay summable. Test asserts both branches |
| 12 | Refuse/warn on cleartext HTTP export with token; `secret()` in `note`/`navigate` | Done | p1-improvements | http exporter refuses token over `http://` (warns when no token); `note`/`note_if_selector` print verbatim (no secret resolution) so notes can't leak secrets to the run log. `navigate` still resolves (URLs legitimately carry tokens). Tests + docs updated |

## P2 — Architecture evolution

| # | Item | Status | PR / Commit | Notes |
| - | --- | --- | --- | --- |
| 13 | Async `/invoke` (202 + poll) | Done | p2-async-invoke | `/invoke` now validates synchronously then returns `202 {run_id, status:"queued"}`; a single worker thread runs invokes serially under `@invoke_mutex` (v1 serialization preserved) and `GET /runs/:id` reports `queued`/`running`/`done`/`error`/`cancelled` + the result. Client disconnect no longer wastes a run. Bounded queue (`max_queued_runs`→503) + FIFO-evicted retention (`max_retained_runs`); inline creds scrubbed from the record at finalize. Cancel now also works on still-queued runs; shutdown drains the worker and aborts the backlog |
| 14 | Structured run events + minimal observability | Not started | | |
| 15 | Container hardening + token lifecycle | Done | p2-hardening-and-tests | Wrapper + documented raw `docker run` now apply `--cap-drop ALL`, `--security-opt no-new-privileges`, `--read-only` + tmpfs (`/tmp`, `~/.config`, `~/.local`, `~/.pki`) — verified Chrome+Xvfb launch under read-only rootfs against the ING flag set. Token lifecycle: server accepts a *set* of tokens (`invoke_tokens:`), assembled by `InvokeServer.load_tokens` from `--invoke-token`(repeatable) + `FREENTONIC_INVOKE_TOKEN`(comma) + `--invoke-token-file`/`FREENTONIC_INVOKE_TOKEN_FILE`(one per line) → zero-downtime rotation; wrapper mounts the token file so the secret stays out of `docker inspect`. Deferred: in-container user-namespace Chrome sandbox (still `--no-sandbox`) |
| 16 | Retire cheapest untested risk (engine, connect, export fan-out, etc.) | Done | p2-hardening-and-tests | New/expanded unit tests (+74): `engine` `stages_to_run` skip-matrix; `chrome_cdp` pure helpers (cookie domain/path/dedupe/format, `pgrep_pattern_for`, `resolve_profile_dir_from_env`, WS frame encode/decode round-trip); `Source#extract_credentials` require/validate/map/derive; `Stages::Export` fan-out (all run, first error re-raised); `Stages::Connect` `initial_url_from_workflow` + `ChromeCdp::Error`/`KeyError`→`UserError` wrapping; multi-token `load_tokens`/`authenticated?`. The P0-gap items it listed (dot-ids, shutdown drain, submit-not-in-flight, await-over-HTTP) were already covered by the P0 work |

## P3 — Direction

| # | Item | Status | PR / Commit | Notes |
| - | --- | --- | --- | --- |
| 17 | Declarative extractor plan (`extract: plan:`) | Not started | | |
| 18 | Export resilience (retry, aggregate errors, stream injection) | Not started | | |
| 19 | Plugin/registry unification (Exporters vs Secrets `build` signatures) | Not started | | |
| 20 | Internal `api_client.rb` split (mechanical) | Not started | | |
| 21 | Workflow schema versioning policy | Not started | | Pairs with #6 changelog backfill |

## Summary

- Total items: 21
- Done: 15 (all of P0 + all of P1 + P2 #13, #15, #16)
- In progress: 0
- Not started: 6 (P2 #14 + all of P3)
