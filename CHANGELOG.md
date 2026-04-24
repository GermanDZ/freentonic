# Changelog

All notable changes to freentonic are documented here.

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
