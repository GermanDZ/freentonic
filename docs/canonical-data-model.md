# Freentonic Canonical Data Model Specification (v0.1)

## Overview

This document defines the canonical internal data model for a bank
aggregation system based on scraping and normalization.

The Normalize stage's output contract IS this canonical model. It is the
single source of truth inside the pipeline; all external output shapes
(CSV, NDJSON, etc.) are produced from it by the exporters.

### Goals

- Normalize heterogeneous bank data into a consistent structure.
- Support balances, transactions, accounts, liabilities, and investments.
- Enable export in multiple shapes (canonical JSON, CSV, NDJSON).
- Handle incomplete and inconsistent scraped data.
- Provide a stable base for future extensions.

## Design Principles

### 1. Canonical First

The internal model is the single source of truth. All external shapes
(canonical JSON, CSV, NDJSON) are derived from it by the exporters.
Normalizers never emit external shapes directly.

### 2. Permissive Schema

Scraped data is unreliable. The model must:

- Allow missing optional fields (construct with `nil`).
- Avoid strict validation at ingestion for fields the bank may omit.
- Store unknown source-specific data in `metadata`.

Only the minimum-required fields per entity (see below) are enforced; every
other field defaults to `nil` when omitted by the normalizer author.

### 3. Raw vs Normalized Data

Every entity carries a `source_id` first-class field holding the raw bank-side
identifier. This is distinct from the canonical `id`: `source_id` is useful
for within-source debugging and reconciliation, but is NOT guaranteed unique
across sources. Never use `source_id` for cross-source joins — use the
canonical `id` for that.

Additional raw-vs-clean pairs appear on `Transaction`:

- `description` — cleaned display text
- `raw_description` — original bank text, untouched

### 4. Deterministic IDs

Canonical IDs must be stable across syncs to prevent duplication. The
`Freentonic::Canonical` module ships four helpers that produce consistent
IDs; normalizer authors MUST use them rather than hand-rolling hashes, to
ensure that two normalizers for the same bank (or the same user running the
same bank twice) produce the same ID for the same underlying record.

Algorithm (all four helpers):

- SHA-256 of the joined component string, truncated to 16 hex chars.
- Components joined by `\x1f` (ASCII unit separator) — impossible in raw
  bank text, so no escaping ambiguity.
- Missing components become the empty string (never `nil.to_s`), so the
  hash remains deterministic.
- Prefix per entity: `txn_`, `acc_`, `liab_`, `inv_`.

Per-entity recipes:

| Helper                        | Components                                           |
| ----------------------------- | ---------------------------------------------------- |
| `Canonical.transaction_id`    | `account_id`, `date` (ISO), `amount` (`to_s("F")`), `raw_description` (stripped) |
| `Canonical.account_id`        | `institution`, then `iban` if present, else `source_id` if stable, else `name` |
| `Canonical.liability_id`      | `account_id`, `type`, optional sub-ref               |
| `Canonical.investment_id`     | `account_id`, `symbol`                               |

When inputs cannot produce a stable ID (e.g., an account with no IBAN, no
stable source ref, and a display name the bank rotates), the helper raises
loudly rather than silently generating a drifting ID. Authors must supply a
stable ref via the helper's `stable_ref:` override in that case, or accept
that the record is inherently non-stable.

### 5. Currency Awareness

All monetary values carry an ISO 4217 currency code as a sibling field on
the entity that owns them. Currency codes are NOT validated against the ISO
list at ingestion (permissive schema); downstream consumers may do so.

### 6. Time Semantics

Transactions support both:

- `date` — booking date
- `value_date` — settlement date

### 7. Money & Quantity Representation

- **Internal Ruby type:** `BigDecimal` for all monetary amounts and
  investment quantities. Float is rejected because summation drift in the
  `summary` rollup (see below) and in downstream consumers is
  unacceptable.
- **Wire JSON type:** **string** (e.g., `"amount": "-45.20"`). Matches
  industry convention (Stripe, most PSD2 APIs) and preserves
  exact precision across the wire. JS/TS consumers parse with a decimal
  library or `parseFloat` (their choice).
- The entity factory coerces `String | Numeric → BigDecimal` so authors
  may pass `"45.20"` or `45.20` and get the same internal value.

### 8. Dates & Timestamps

- **Internal Ruby type:** `Date` for day-precision fields (`date`,
  `value_date`, `due_date`), `Time` (UTC) for instant fields (`balance.timestamp`,
  `summary.generated_at`).
- **Wire JSON type:** ISO strings — `"2026-04-20"` for dates,
  `"2026-04-23T10:00:00Z"` for timestamps.

## Ruby Representation

### Module layout

```
lib/freentonic/canonical.rb                 # top-level module + SCHEMA_VERSION
lib/freentonic/canonical/payload.rb         # CanonicalPayload wrapper class
lib/freentonic/canonical/account.rb         # Data.define + factory
lib/freentonic/canonical/balance.rb         # Data.define
lib/freentonic/canonical/transaction.rb     # Data.define + factory
lib/freentonic/canonical/merchant.rb        # Data.define
lib/freentonic/canonical/liability.rb       # Data.define + factory
lib/freentonic/canonical/investment.rb      # Data.define + factory
lib/freentonic/canonical/ids.rb             # deterministic-ID helpers
lib/freentonic/canonical/summary.rb         # framework-computed summary
```

### Schema version

```ruby
Freentonic::Canonical::SCHEMA_VERSION = "0.1"
```

Semver string. Bump the version when a field is renamed or removed in the
envelope or any entity; additive changes (new optional fields) do NOT bump.
Receivers that want to be strict can reject anything other than `"0.1"`;
lenient receivers can major-version-match. Bump to `"1.0"` when the spec
leaves Draft status.

### Entity representation

All entities are `Data.define` value objects with a thin module-level
factory that defaults optional fields to `nil`. Authors call
`Canonical::Transaction.new(id:, account_id:, amount:, currency:)` and
get a fully-populated value object with every other slot nil-defaulted.

Immutable by construction (`Data.define` semantics). Equality is
structural. `to_h` is free and is what exporters use for serialization.

## Core Entities

### Envelope: `CanonicalPayload`

The top-level object a normalizer returns. Serializes to:

```json
{
  "schema_version": "0.1",
  "summary": { "...": "see below" },
  "meta": {},
  "accounts": [ ... ],
  "transactions": [ ... ],
  "liabilities": [ ... ],
  "investments": [ ... ]
}
```

Fields:

- `schema_version` — always `Canonical::SCHEMA_VERSION`. Filled in by the
  envelope, not the author.
- `summary` — framework-computed at construction time. See [Summary](#summary).
  Authors may pass `summary:` explicitly to override (rare; e.g., a scraper
  knows it has a partial window and wants to annotate that).
- `meta` — free-form hash. Envelope-level metadata (scraper version, source
  timestamp, etc.). `freentonic_run_id` is merged in automatically by the
  HTTP exporter if the env var is set.
- `accounts` / `transactions` / `liabilities` / `investments` — arrays of
  canonical entities. Empty arrays allowed; missing slots treated as empty.

Extensible: future entity types are added as new top-level slots.

### Account

Represents a financial account.

```json
{
  "id": "acc_a1b2c3d4e5f60718",
  "source_id": "12345678",
  "institution": "bbva",
  "name": "Main Account",
  "type": "checking",
  "currency": "EUR",
  "iban": "ES1234567890",
  "balance": {
    "current": "1200.50",
    "available": "1150.20",
    "timestamp": "2026-04-23T10:00:00Z"
  },
  "metadata": {}
}
```

Fields:

- `id` (required) — canonical stable ID; see [Deterministic IDs](#4-deterministic-ids).
- `source_id` — raw bank-side identifier. May be non-unique across sources.
- `currency` (required) — ISO 4217 code.
- `institution` — source bank identifier slug.
- `name` — display name.
- `type` — `checking`, `savings`, `credit_card`, `investment`, etc.
- `iban` — optional.
- `balance.current` / `balance.available` — `BigDecimal` internally,
  string on wire. Either may be `nil` if the bank doesn't expose it.
- `balance.timestamp` — `Time` (UTC) internally; ISO8601 string on wire.
- `metadata` — free-form bank-specific extras.

Minimum-required fields to construct: `id`, `currency`.

### Transaction

Represents a financial movement.

```json
{
  "id": "txn_4a5b6c7d8e9f0a1b",
  "source_id": "REF-998877",
  "account_id": "acc_a1b2c3d4e5f60718",
  "date": "2026-04-20",
  "value_date": "2026-04-21",
  "amount": "-45.20",
  "currency": "EUR",
  "description": "Amazon purchase",
  "raw_description": "AMZN Mktp ES*XYZ",
  "status": "posted",
  "merchant": {
    "name": "Amazon",
    "normalized": true
  },
  "category": null,
  "metadata": {}
}
```

Fields:

- `id` (required) — deterministic; produced by `Canonical.transaction_id`.
- `source_id` — raw bank-side transaction reference.
- `account_id` (required) — canonical account ID reference.
- `amount` (required) — signed BigDecimal; string on wire.
- `currency` (required) — ISO 4217.
- `date` — booking date (`Date` / ISO string).
- `value_date` — settlement date (`Date` / ISO string).
- `description` — cleaned.
- `raw_description` — untouched source text.
- `status` — `"pending"` | `"posted"`.
- `merchant` — optional nested record with `name` and `normalized` flag.
- `category` — optional classification string.
- `metadata` — free-form.

Minimum-required fields to construct: `id`, `account_id`, `amount`,
`currency`. `date` is intentionally NOT required — scraped data frequently
omits it and fabricating a date to satisfy a required-field constraint is
worse than leaving it `nil` and letting consumers handle the gap.

### Liability

Represents debts such as credit cards or loans.

```json
{
  "id": "liab_abc123def4567890",
  "source_id": "CC-42",
  "type": "credit_card",
  "account_id": "acc_a1b2c3d4e5f60718",
  "balance": "-500.00",
  "limit": "2000.00",
  "currency": "EUR",
  "due_date": "2026-05-01",
  "metadata": {}
}
```

Fields:

- `id` (required) — produced by `Canonical.liability_id`.
- `source_id` — raw bank-side ref.
- `type` (required) — `credit_card`, `loan`, `mortgage`, etc.
- `account_id` — linked canonical account ID (optional but strongly
  recommended when the bank associates them).
- `balance` — outstanding amount (BigDecimal / string).
- `limit` — credit limit if applicable.
- `currency` (required) — ISO 4217.
- `due_date` — optional (`Date` / ISO string).
- `metadata` — free-form.

Minimum-required fields to construct: `id`, `type`, `currency`.

### Investment

Represents investment holdings.

```json
{
  "id": "inv_0011223344556677",
  "source_id": "POS-AAPL-1",
  "account_id": "acc_a1b2c3d4e5f60718",
  "type": "stock",
  "symbol": "AAPL",
  "quantity": "10",
  "price": "170.25",
  "currency": "USD",
  "metadata": {}
}
```

Fields:

- `id` (required) — produced by `Canonical.investment_id`.
- `source_id` — raw bank-side position ref.
- `account_id` (required) — linked canonical account ID.
- `type` — `stock`, `fund`, `crypto`, etc.
- `symbol` (required) — asset identifier.
- `quantity` — units held (BigDecimal / string; fractional supported).
- `price` — last known price (BigDecimal / string).
- `currency` (required) — ISO 4217.
- `metadata` — free-form.

Minimum-required fields to construct: `id`, `account_id`, `symbol`,
`currency`.

## Summary

The envelope's `summary` field is computed by the framework at
`CanonicalPayload.new` time. Shape:

```json
{
  "counts": {
    "accounts": 3,
    "transactions": 147,
    "liabilities": 1,
    "investments": 0
  },
  "amounts_by_currency": {
    "EUR": "-523.40",
    "USD": "1200.00"
  },
  "balances_by_currency": {
    "EUR": "4250.20"
  },
  "date_range": {
    "earliest": "2026-03-01",
    "latest": "2026-04-22"
  },
  "generated_at": "2026-04-23T10:05:12Z"
}
```

- `counts` — one entry per slot; zero for empty slots.
- `amounts_by_currency` — sum of transaction `amount`s, grouped by `currency`.
  BigDecimal sums formatted as fixed-point strings.
- `balances_by_currency` — sum of account `balance.current`, grouped by
  account `currency`. Accounts with nil balances are skipped.
- `date_range` — min/max over transaction `date`; nil transactions skipped.
  If no transaction has a date, the block is `null`.
- `generated_at` — wall-clock time of envelope construction, UTC ISO8601.

Authors may override by passing `summary:` to `CanonicalPayload.new`;
passing `nil` disables computation (summary becomes `null` on wire).

## Metadata Strategy

Every entity and the envelope carry a `metadata` hash. Use it for:

- Bank-specific fields that don't map to any canonical slot.
- Debug info (scraper version, fetch timestamps).
- Unmapped source attributes worth preserving for later reprocessing.

Do NOT use `metadata` as a bypass for fields that DO have a canonical slot.
If a bank gives you IBAN, put it in `account.iban`, not `metadata["iban"]`.

## Data Flow

1. **Input layer** — bank scrapers (YAML-declared workflows), raw HTTP/API
   responses, cookie capture, etc.
2. **Extract stage** — producer-specific Ruby class converts raw bytes
   into a bank-shaped intermediate payload.
3. **Normalize stage** — producer-specific Ruby class converts the
   intermediate payload into a `CanonicalPayload`. After migration, this is
   the universal contract; every normalizer returns one.
4. **Export stage** — fans out to one or more Exporters. Each Exporter
   renders the canonical payload into its wire shape and ships it (POST,
   file write, etc.).

## Future Extensions (out of scope for v0.1 migration)

Planned additions, each tracked as its own follow-up:

- Transfers between accounts (cross-entity links).
- Category normalization engine.
- Exchange rates / FX conversions.
- Event sourcing (transaction history changes).
- Webhook delivery.
- Storage layer (currently stateless).

## Summary

Core stack:

- `Freentonic::Canonical` module — envelope + entities + helpers.
- YAML-declared workflows driving extract + normalize.
- Pluggable exporters (HTTP, JSON-file, CSV-file, JSONL-file) rendering
  the canonical payload into their wire shapes directly.

This architecture ensures flexibility, extensibility, and long-term
maintainability while giving consumers one stable internal shape to target.
