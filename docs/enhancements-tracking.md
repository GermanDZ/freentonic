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
| 8 | `freentonic --lint` dry-run | Not started | | Depends on #7 (registry now available) |
| 9 | Close pre-auth slow-drip DoS on invoke server | Not started | | |
| 10 | Confine server-supplied paths (`credentials.file`, `extract.ruby`/`ext.file`) | Not started | | |
| 11 | CSV formula-injection guard | Not started | | |
| 12 | Refuse/warn on cleartext HTTP export with token; `secret()` in `note`/`navigate` | Not started | | |

## P2 — Architecture evolution

| # | Item | Status | PR / Commit | Notes |
| - | --- | --- | --- | --- |
| 13 | Async `/invoke` (202 + poll) | Not started | | |
| 14 | Structured run events + minimal observability | Not started | | |
| 15 | Container hardening + token lifecycle | Not started | | |
| 16 | Retire cheapest untested risk (engine, connect, export fan-out, etc.) | Not started | | |

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
- Done: 6 (all of P0)
- In progress: 0
- Not started: 15
