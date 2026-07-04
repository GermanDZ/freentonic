# Changelog

All notable changes to freentonic are documented here.

With providers living in a separate repo, the workflow YAML dialect and
the invoke-server API **are** freentonic's public contract — this
changelog is their version signal. Every release below corresponds to a
`version.rb` bump and a matching `vX.Y.Z` git tag.

## Unreleased

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
