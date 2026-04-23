# Canonical Data Model — Migration Plan

## Context

We are adopting the canonical data model specified in
[canonical-data-model.md](canonical-data-model.md) as the Normalize
stage's output contract, and introducing a Formatter layer
([formatters.md](formatters.md)) that converts the canonical payload into
the shape each exporter ships.

This migration is sequenced as **six sequential PRs**, designed so that:

- Steps 1–3 are **pure additions** — trunk stays green, no existing code
  path is touched.
- Step 4 is the **one unavoidable breaking change** to existing
  `csv`/`jsonl` users (`--export-csv-select` is removed).
- Step 5 proves the full end-to-end pipeline inside the repo's example.
- Step 6 is the **semantic flip** — `http`/`json` exporters now require
  canonical-producing normalizers. Release as a minor version bump with
  migration notes for external workflow authors.

Different teams / sessions can pick up each step independently in
sequence. They cannot run in parallel — each step depends on the previous
step having landed.

## Foundational decisions (already resolved)

Before reading the steps, confirm you have these anchored. They are final
and should not be re-litigated:

| Decision                        | Value                                                                 |
| ------------------------------- | --------------------------------------------------------------------- |
| Normalize output contract       | `CanonicalPayload`                                                    |
| Envelope top-level keys         | `schema_version`, `summary`, `meta`, `accounts`, `transactions`, `liabilities`, `investments` |
| Entity representation           | `Data.define` value objects with thin factory defaulting optionals to `nil` |
| Money/quantity internal type    | `BigDecimal` (coerced from `String` or `Numeric` in factory)          |
| Money/quantity wire type        | JSON string (`"amount": "-45.20"`)                                    |
| Date/time internal types        | `Date` / `Time` (UTC)                                                 |
| Date/time wire type             | ISO strings                                                           |
| `source_id` field               | First-class on every entity. Unique within source only.               |
| Deterministic IDs               | SHA-256 truncated to 16 hex chars, `\x1f` joiner, per-entity prefix   |
| Formatter layer                 | Separate `Freentonic::Formatters` registry; built-in only for now     |
| HTTP default format             | `canonical`                                                           |
| No legacy back-compat formatter | User will migrate their receiver at step 6                            |
| `--export-format`               | Universal flag across exporters; attaches to most-recent `--export`   |
| Summary field                   | Framework-computed at construction, author-overridable                |
| Schema version                  | `"0.1"` (bump on rename/remove; not on additive changes)              |

If any of these feels wrong when you pick up a step, STOP and escalate —
don't silently drift from the spec.

## Step 1 — Introduce `Freentonic::Canonical` module

**Status:** not started.
**Blocking:** step 2 and onward.
**Breaking change:** none (pure addition).

### Scope

Add the canonical model as a standalone, fully-tested module. Nothing
else in the codebase consumes it yet.

### Files created

```
lib/freentonic/canonical.rb                 # top-level module + SCHEMA_VERSION
lib/freentonic/canonical/payload.rb         # CanonicalPayload wrapper
lib/freentonic/canonical/account.rb         # Data.define + factory
lib/freentonic/canonical/balance.rb         # Data.define
lib/freentonic/canonical/transaction.rb     # Data.define + factory
lib/freentonic/canonical/merchant.rb        # Data.define
lib/freentonic/canonical/liability.rb       # Data.define + factory
lib/freentonic/canonical/investment.rb      # Data.define + factory
lib/freentonic/canonical/ids.rb             # deterministic-ID helpers
lib/freentonic/canonical/summary.rb         # framework-computed summary
test/freentonic/canonical/                  # one test file per entity + payload + ids + summary
```

### Files modified

- `lib/freentonic.rb` — `require` the new `canonical.rb` entrypoint so
  `Freentonic::Canonical::...` is usable without manual requires.

### Public API

```ruby
Freentonic::Canonical::SCHEMA_VERSION           # "0.1" constant

Freentonic::Canonical::Account.new(id:, currency:, ...)
Freentonic::Canonical::Transaction.new(id:, account_id:, amount:, currency:, ...)
Freentonic::Canonical::Liability.new(id:, type:, currency:, ...)
Freentonic::Canonical::Investment.new(id:, account_id:, symbol:, currency:, ...)
Freentonic::Canonical::Balance.new(current:, available:, timestamp:)
Freentonic::Canonical::Merchant.new(name:, normalized:)

Freentonic::Canonical::CanonicalPayload.new(
  accounts: [], transactions: [], liabilities: [], investments: [],
  meta: {}, summary: :auto
)
# => computes summary unless summary: is passed explicitly (pass nil to disable)

Freentonic::Canonical.transaction_id(account_id:, date:, amount:, raw_description:)
Freentonic::Canonical.account_id(institution:, iban: nil, source_id: nil, name: nil, stable_ref: nil)
Freentonic::Canonical.liability_id(account_id:, type:, sub_ref: nil)
Freentonic::Canonical.investment_id(account_id:, symbol:)
```

### Requirements & invariants

- Factories coerce `String`/`Numeric` amounts to `BigDecimal`.
- Factories coerce ISO-string dates to `Date` / `Time` if a string is
  passed; pass-through if already the right type.
- Factories reject unknown keyword args with a clear error (catch typos
  early).
- `Data.define` instances are immutable — any attempt to mutate should
  raise (default `Data.define` behavior — don't fight it).
- `CanonicalPayload#to_h` produces wire-ready output: money as string,
  dates/times as ISO strings, nested entities serialized recursively.
- `CanonicalPayload#to_h` always emits `schema_version: SCHEMA_VERSION`
  (authors cannot override the version).
- `Canonical.account_id` raises `Freentonic::UserError` (or a new
  `Canonical::UnstableIdError`) when it cannot produce a stable ID from
  the inputs given — no silent non-determinism.
- `Canonical::Summary.compute(payload)` returns the summary hash; called
  from `CanonicalPayload.new` unless the caller overrode.

### Tests

- Entity construction: happy path + required-field-missing raises + type
  coercion (string → BigDecimal, string → Date).
- Envelope `to_h` round-trip: build, serialize, `JSON.parse`, structural
  compare against a golden fixture.
- Deterministic IDs: same inputs → same output across calls; different
  inputs → different output; missing optional component handled; unstable
  account input raises.
- Summary: counts, amounts_by_currency (BigDecimal addition precision),
  balances_by_currency, date_range (including the all-nil case), override
  passes through untouched.
- Factory unknown-key rejection.

### Acceptance

- All tests green.
- `ruby -e "require 'freentonic'; p Freentonic::Canonical::SCHEMA_VERSION"`
  prints `"0.1"`.
- `yard` / `rdoc` render cleanly (if present in repo — check `Rakefile`).
- NO existing test changes required.

## Step 2 — Introduce `Freentonic::Formatters` module

**Status:** blocked by step 1.
**Breaking change:** none (pure addition).

### Scope

Add the formatter registry and the three first-cut built-in formatters.
Exporters do not consume formatters yet — that's step 3.

### Files created

```
lib/freentonic/formatters.rb                    # auto-require entry
lib/freentonic/formatters/base.rb               # Base + registry
lib/freentonic/formatters/canonical.rb          # identity formatter
lib/freentonic/formatters/csv_transactions.rb   # flatten .transactions → CSV string
lib/freentonic/formatters/jsonl_transactions.rb # flatten .transactions → NDJSON string
test/freentonic/formatters/                     # one test per formatter + base registry
```

### Files modified

- `lib/freentonic.rb` — `require "freentonic/formatters"`.

### Public API

See [formatters.md](formatters.md). The contract, return-type rules, and
`content_type` discipline are defined there.

### Requirements & invariants

- `Formatters.build(:unknown_name)` raises `Freentonic::UserError` with the
  list of registered names.
- `CsvTransactions` / `JsonlTransactions` hoist `account_*` context columns
  from the canonical `accounts` slot, keyed on `transaction.account_id`.
  Orphan transactions (account_id not found in the accounts slot) still
  emit a row — `account_*` columns come out blank, not errored.
- Column ordering for `CsvTransactions` is deterministic: union of all row
  keys, sorted ASCII-ascending. Reproducibility matters for downstream
  diffing.
- `JsonlTransactions` content-type is `application/x-ndjson`.
- Money fields are already strings by the time the formatter sees them
  (payload is serialized via `to_h`). Formatters DO NOT call BigDecimal
  methods directly.

### Tests

- Golden-output test per formatter against a shared canonical fixture
  (multi-account, multi-currency, pending + posted transactions,
  a liability, an investment).
- `content_type` declared value per formatter.
- Registry: `build(:canonical)` / `build(:csv_transactions)` / `build(:jsonl_transactions)`
  all return the right class; `build(:nope)` raises.
- `Canonical#call` output JSON-parses back into a structure equal to
  `payload.to_h`.

### Acceptance

- All tests green.
- No existing exporter behavior changed — `test/freentonic/exporters/` all
  still pass untouched.

## Step 3 — Wire `--export-format` into CLI and `Exporters::Base`

**Status:** blocked by step 2.
**Breaking change:** none. Existing `http`/`json` behavior unchanged
(default format is `canonical`, and when the payload happens to already be
a plain Hash like today's ad-hoc normalizer output, `Canonical#call` still
emits it via `to_h` — Hashes respond to `to_h`, so behavior is preserved
for the legacy case too; if you want absolute zero-risk: add a
type-sniff so that non-CanonicalPayload inputs skip the formatter and
emit as before, document as deprecated).

### Scope

Plumb formatter selection from CLI to exporter. No exporter changes its
user-visible default output shape yet.

### Files modified

- `lib/freentonic/cli.rb`
  - Add `opts.on("--export-format NAME", ...)` attaching `:format` to the
    most-recent exporter via the existing `attach` helper.
- `lib/freentonic/exporters/base.rb`
  - Add `resolve_formatter` and `default_format` helpers.
  - Add a small helper `apply_formatter(payload)` that branches on the
    formatter's return type (`Hash/Array` → `JSON.generate`, `String` →
    pass-through) for exporters that want shared plumbing.
- `lib/freentonic/exporters/http.rb`
  - Call `resolve_formatter` before sending. Use
    `formatter.content_type` unless `@options[:content_type]` overrides.
  - Keep the `with_run_id_meta` merge but apply it only when the
    formatter output is a Hash (String outputs from OFX-style formatters
    have nowhere to merge a meta key).
- `lib/freentonic/exporters/json.rb`
  - Call `resolve_formatter`; default `canonical`. Handle both Hash/Array
    and String outputs.
- `lib/freentonic/exporters/jsonl.rb` — NO changes yet; rewritten in step 4.
- `lib/freentonic/exporters/csv.rb` — NO changes yet; rewritten in step 4.
- `test/freentonic/cli_test.rb` (or wherever CLI parsing is covered) —
  assert `--export-format` attaches correctly.

### Defaults per exporter (for this step)

| Exporter | `default_format` |
| -------- | ---------------- |
| `http`   | `:canonical`     |
| `json`   | `:canonical`     |
| `jsonl`  | (still uses legacy path; step 4 changes this) |
| `csv`    | (still uses legacy path; step 4 changes this) |

### Requirements & invariants

- `--export-format NAME` without a preceding `--export` raises the same
  "flag before --export NAME" error the existing per-exporter flags raise.
- `--export-format` attached to an unknown name raises at CLI parse time,
  not at export time — fail fast.
- When the `http` formatter returns a Hash, the existing
  `with_run_id_meta` merge is applied (preserves current behavior).
- When the formatter returns a String, `Content-Type` is set from
  `formatter.content_type` unless `--export-content-type` is passed.

### Tests

- CLI: `--export http --export-format canonical` attaches correctly.
- CLI: `--export-format` before any `--export` raises.
- CLI: `--export http --export-format unknown_name` raises.
- HTTP exporter: with a stub formatter returning `"<xml/>"` and
  `content_type "application/x-ofx"`, POST body is `<xml/>` and header
  `Content-Type: application/x-ofx`.
- HTTP exporter: existing tests still pass unchanged (canonical formatter
  on a plain hash preserves today's wire shape).

### Acceptance

- All tests green, including pre-existing exporter tests.
- `bin/freentonic --help` lists the new `--export-format` flag.

## Step 4 — Rewrite `csv` and `jsonl` exporters; remove `--export-csv-select`

**Status:** blocked by step 3.
**Breaking change:** **YES.** `--export-csv-select` is removed; `csv` and
`jsonl` exporters now assume a canonical-shaped input and flatten the
`transactions` slot by default. Any user relying on today's
generic-select behavior must update their invocation.

### Scope

Replace the body of `csv.rb` and `jsonl.rb` with thin wrappers that:
1. Resolve the formatter via `resolve_formatter` (default
   `csv_transactions` / `jsonl_transactions`).
2. Call the formatter.
3. Write the resulting `String` to `@options[:path]` or stdout.

### Files modified

- `lib/freentonic/exporters/csv.rb` — rewritten to ~15 lines delegating to
  the formatter.
- `lib/freentonic/exporters/jsonl.rb` — same.
- `lib/freentonic/cli.rb`
  - Remove the `--export-csv-select PATH` flag definition entirely.
  - Remove any tests that exercise it.
- `README.md` / CLI help — strike references to `--export-csv-select`.
- Release notes / `CHANGELOG.md` (or Git commit body if no changelog file)
  — call out the removal prominently.
- `test/freentonic/exporters/csv_test.rb` and `jsonl_test.rb` — rewritten
  against `CanonicalPayload` fixtures.

### Rationale for removal

Under the canonical model, slot names are fixed (`accounts`,
`transactions`, `liabilities`, `investments`). The `--export-csv-select`
flag existed because pre-canonical payloads had arbitrary shapes; its
reason for existing is gone. Keeping it as a no-op or override would
invite bug reports ("why does `--export-csv-select investments` silently
do nothing?") and block the "slot names are fixed, formatters know where
to look" simplification.

If a user later needs alternative flattenings (e.g., one row per account
instead of one per transaction), they add a new formatter
(`CsvAccounts`) — which is cheaper and clearer than reviving a generic
selector flag.

### Requirements & invariants

- `csv` and `jsonl` now REQUIRE a `CanonicalPayload`-shaped input. If
  handed a plain Hash that isn't canonical-shaped, they raise a clear
  `UserError` naming the step-6 migration as the root cause.
- No change in default output filename / stdout behavior — path logic is
  untouched.

### Tests

- `csv_transactions` formatter's golden fixture is the same one used by
  the `csv` exporter's integration test; they should produce the same
  bytes through either code path.
- Error case: `Exporters::Csv.new(...).write({ "foo" => "bar" })` raises
  with a message pointing at the canonical migration.

### Acceptance

- All tests green.
- `bin/freentonic --help` no longer lists `--export-csv-select`.
- `CHANGELOG` entry present and clear.

## Step 5 — Migrate the example workflow's normalizer to emit canonical

**Status:** blocked by step 4.
**Breaking change:** only for anyone running the in-repo example.

### Scope

Update `examples/example_bank.yml` and its `normalizer.rb` so the
normalizer returns a `CanonicalPayload`. This is both the in-repo proof
of end-to-end correctness and the authoring template external workflow
authors will copy.

### Files modified

- `examples/example_bank.yml` — minor doc comments, unchanged structure.
- `examples/normalizer.rb` — rewritten to build a `CanonicalPayload`,
  using `Canonical.account_id` / `Canonical.transaction_id` / etc.
- `examples/extractor.rb` — may or may not need tweaks depending on what
  shape it feeds the normalizer today; check and minimize churn.
- `test/freentonic/integration/example_bank_test.rb` (or equivalent) —
  updated to assert the example produces canonical-shaped output end to
  end.
- `docs/writing-plugins.md` (if present) — update the normalizer section
  to show a canonical-building example.

### Requirements & invariants

- The example covers: at least two accounts with different currencies,
  a mix of pending and posted transactions, at least one transaction
  missing a `value_date`, and at least one account with `balance.available`
  set.
- Running `bin/freentonic invoke examples/example_bank.yml --export json
  --export-path /tmp/out.json` produces valid canonical JSON that
  matches a checked-in golden fixture.

### Acceptance

- All tests green.
- The example, run with `--export csv --export-path /tmp/out.csv`,
  produces a CSV whose first line is the deterministic column header
  set expected by the `csv_transactions` golden fixture.
- The example, run with `--export http --export-url <mock>`, POSTs
  canonical JSON with `Content-Type: application/json` and a
  `schema_version: "0.1"` root field.

## Step 6 — Flip `http` / `json` exporter defaults; release as minor version bump

**Status:** blocked by step 5.
**Breaking change:** **YES.** External workflow authors whose normalizers
still emit ad-hoc shapes will see those shapes passed unchanged through
the `Canonical` formatter (identity on Hash inputs) — behavior is
preserved but they no longer get `schema_version` / `summary` / etc. To
actually benefit from the migration they must update their normalizer.
External HTTP receivers built against the old ad-hoc shape will need to
be updated.

### Scope

The actual semantic cutover. After this PR, the canonical model is THE
contract and the spec doc is authoritative.

### Files modified

- `lib/freentonic/version.rb` — bump minor version.
- `CHANGELOG.md` — prominent migration notes:
  - `schema_version` / `summary` / `meta` envelope fields now present on
    canonical output.
  - Entity IDs are now deterministic and prefixed (`txn_`, `acc_`, …).
  - Money fields on the wire are now strings.
  - `--export-csv-select` is gone (was step 4; repeat for loud release
    notes).
  - Point authors at `docs/canonical-data-model.md` and
    `docs/writing-plugins.md`.
- `docs/canonical-data-model.md` — drop the "(v0.1)" Draft qualifier once
  we're confident no breaking changes are needed in the v0.1 shape based
  on real usage. (Optional; can be deferred to a follow-up.)
- `docs/getting-started.md` — update any snippets showing normalizer
  output.

### Concrete action for THIS repo's author

The project author (`germ@ndz.com.ar`) has a deployed receiver consuming
the current HTTP exporter output. Before merging step 6:

1. Verify the receiver is updated to parse canonical-shaped JSON.
2. Coordinate the deploy timeline so receiver update and freentonic
   release land in the right order.

This is called out explicitly because it's the one action that the
codebase cannot verify automatically.

### Requirements & invariants

- No code-path branches remain anywhere of the form "if payload is
  canonical then X else legacy" — post-step-6, canonical IS the contract,
  and adapters for non-canonical inputs would be a smell.
- README's quickstart example produces canonical output when followed
  literally.

### Acceptance

- All tests green.
- Fresh checkout of main, run `bin/freentonic invoke examples/example_bank.yml
  --export json` — output starts with `{"schema_version":"0.1",...`.
- `gem build` succeeds with the new version.
- Release notes reviewed and merged.

## Post-migration backlog (do NOT bundle into the six steps)

Tracked separately once the six steps land:

- `Formatters::SimpleFIN` — dedicated PR with format research + golden
  fixtures against the SimpleFIN spec.
- `Formatters::Ofx` — dedicated PR; XML serialization, strict formatting.
- Plugin-loadable formatters (`formatters:` block in workflow YAML),
  mirroring the `normalize:` plugin pattern.
- Storage layer (stateful sync state).
- Transfers-between-accounts entity + linkage.
- Categories normalization engine.
- Exchange-rate support.

## Handoff checklist for each step

When picking up a step in a fresh session:

1. Read this file and the "Foundational decisions" table above.
2. Read the referenced spec docs
   ([canonical-data-model.md](canonical-data-model.md) for steps 1, 5, 6;
   [formatters.md](formatters.md) for steps 2, 3, 4).
3. Verify the previous step has landed in `main` (check git log for the
   step's acceptance criteria).
4. Follow the step's "Files created" / "Files modified" lists; do not
   silently add scope.
5. Run the full test suite and the acceptance checks before opening the PR.
6. If a decision feels wrong, STOP and escalate — don't drift from the
   foundational decisions without revisiting them explicitly.
