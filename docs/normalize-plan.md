# Declarative normalizers (`normalize: plan:`)

A normalizer turns the raw provider payload (whatever the extractor
returned) into the canonical model — accounts, transactions,
liabilities. For a provider whose normalizer is field-mapping and
straight-line data shaping, that Ruby can be replaced with a declarative
`normalize: plan:` block. No sibling `normalizer.rb`, zero provider Ruby
on the normalize side.

A normalize plan reuses the [`extract: plan:`](extract-plan.md) step
grammar — with one difference: **there is no `fetch:`**. Normalization
runs after extraction, offline, over a payload already sitting in
context. A normalize plan is therefore a *total, offline* computation:
raw in, canonical out, replayable via `--from-raw` forever, with zero
provider-authored code executing during a sync.

## When to use a plan (and when not to)

Use `plan:` when the normalizer would only:

- iterate the raw payload's collections (`for_each:` / `select:`),
- map/rename/coerce fields into canonical entities (`apply:` over the
  builtin functions — `cents`, `parse_date`, `map_status`, `pick`,
  `build_account`, `build_transaction`, `build_liability`, …),
- shape data along the way: coalesce (`let:` + `coalesce:`), merge
  (`concat:`), dedupe (`dedup_by:`), build/read lookup maps
  (`index_by:` / `lookup:`), guard rows (`skip_when:` / `when:`).

Keep the `{ruby:, class:}` escape hatch when the transform needs an
algorithm the fixed verb set can't express — a cross-row reconciliation,
a prefix-dup collapse, a marker-gated reshape. Those are being lifted
into freentonic as *parameterized* `apply:` functions (Ask 9); until a
given algorithm has a function, its provider stays on Ruby. A plan's
`when:`/`skip_when:` gates speak only the `when_context` operator set
(numeric comparisons, equality, presence) over a single binding — never
string matching or arithmetic.

Revolut is the canonical plan normalizer. ING — with its per-plastic
balance reconciliation and pre-clearing dedup — is the canonical
escape-hatch normalizer until Ask 9 lands its algorithms.

## The two forms

```yaml
# Declarative
normalize:
  plan:
    steps: [ ... ]
    output:
      accounts:     "{accounts}"
      transactions: "{transactions}"
      liabilities:  "{liabilities}"   # optional

# Escape hatch (deleted in Ask 10)
normalize:
  ruby:  ./normalizer.rb
  class: Freentonic::Providers::Foo::Normalizer
```

Exactly one form per workflow; declaring both is a load error.

## Seeded bindings

A normalize plan starts with three bindings (deliberately fewer than an
extract plan — a normalizer that read the clock would break replay):

| Binding | Value |
|---|---|
| `raw` | the extract payload — the hash the extractor / `--from-raw` produced |
| `config` | the provider's `config.yml`, so `{config.institution}`, `{config.status_map}`, `{config.field_aliases}` resolve |
| `today` | `Date.today` (the one clock read a normalizer legitimately needs, e.g. a default date) |

`now_ms` / `from_ms` / `from_date` are **not** seeded here — a normalize
plan must be a pure function of `raw` for `--from-raw` to reproduce it.

## Output contract

`output:` binds entity lists only — `accounts:` and `transactions:` are
required, `liabilities:` is optional. The stage assembles the
`CanonicalPayload` envelope itself, stamping `meta.scraper_version` from
`config.yml`. Plans never build the envelope, and no other `output:` key
is allowed.

## Worked example (Revolut)

```yaml
normalize:
  plan:
    steps:
      # --- pockets → checking accounts (+ their transactions) ---
      - select: { from: raw, path: bank_details, default: [] }
        as: bank_details
      - select: { from: raw, path: pockets, default: [] }
        as: pockets
      - for_each: { source: pockets }
        as_item: pocket
        as: pocket_results
        do:
          - select: { from: pocket, path: id }
            as: pocket_id
          - skip_when: { pocket_id: { absent: true } }
          # Revolut pockets share the parent wallet's IBAN — surfacing it
          # on Account#iban would collide canonical ids across EUR
          # pockets. Keep it in metadata; let source_id drive the id.
          - apply: join
            args: { parts: ["pocket:", "{pocket_id}"] }
            as: source_id
          - apply: cents
            args: { amount: "{pocket.balance}", already_minor: true }
            as: balance_cents
          - apply: cents_to_amount
            args: { cents: "{balance_cents}" }
            as: balance_amount
          - apply: build_account
            args:
              institution: "{config.institution}"
              source_id: "{source_id}"
              currency: "{pocket.currency}"
              name: "{pocket.name}"
              type: checking
              balance: { current: "{balance_amount}", timestamp: null }
            as: account
          # ... build this pocket's transactions, keyed on {account.id} ...
          - yield: { account: "{account}", txns: "{txns}" }
      - apply: pluck
        args: { list: "{pocket_results}", key: account }
        as: accounts
      - apply: pluck
        args: { list: "{pocket_results}", key: txns }
        as: txn_groups
      - apply: flatten
        args: { list: "{txn_groups}" }
        as: transactions
    output:
      accounts:     "{accounts}"
      transactions: "{transactions}"
```

Note `{account.id}` in the inner transaction loop: templates and
`select:` paths can walk a canonical entity's declared members (never an
arbitrary method), so a plan chains `build_account` into the
`build_transaction`s attached to it.

## `apply:` and the function registry

`apply: <function>` invokes a **pure function** from the
`Freentonic::Fn` registry with `args:`, binding the result via `as:`.
The registry is the whitelist (the same role the declared-endpoint list
plays for `fetch:`), every function is pure by contract and enforcement
(args deep-frozen before the call), and parameter names are checked at
load time. See [pure-functions-plan.md](pure-functions-plan.md) for the
registry design and the full builtin catalog.

## Validation

Normalize plans are fully statically checkable — `freentonic --lint`
(and workflow load) verifies, with no Chrome, no network, and no
provider Ruby:

- exactly one of `plan:` / (`ruby:` + `class:`),
- **no `fetch:`** (unknown-step error — the endpoint verb is absent from
  the allowed set),
- every `apply:` names a registered function with well-formed args,
- every `{token}` root / `select.from` / `for_each.source` / `when:` key
  references a name bound earlier (starting from `raw` / `config` /
  `today`),
- `output:` binds only `accounts` / `transactions` / `liabilities`, with
  `accounts` and `transactions` required.

## Security note

The interpreter dispatches on a fixed, closed verb set; a normalize plan
has no api_client at all (`fetch:` is both statically rejected and
runtime-guarded). Dispatch to a function is a registry lookup, never a
`send` off YAML. A declarative normalizer therefore runs **no
provider-authored code** — the audit surface for "what does this
provider's normalizer do" is a YAML diff plus the freentonic-owned
function registry.
