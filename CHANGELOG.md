# Changelog

All notable changes to freentonic are documented here.

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
