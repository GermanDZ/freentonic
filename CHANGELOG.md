# Changelog

All notable changes to freentonic are documented here.

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
