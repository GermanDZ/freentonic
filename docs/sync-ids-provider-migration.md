# Sync IDs — Provider Migration Guide

**Audience:** maintainers of `freentonic-providers` (ING, Unicaja, Fintonic,
Revolut, and any future provider).

**Branch in framework:** `sync-ids` (commits `8f57e87` and `070d4ee`). These
must merge to `main` and the gem must be tagged before providers can pin
the new version.

**TL;DR.** The framework changed two ID derivations:

1. `Canonical.transaction_id` now hashes `(account_id, source_id)` whenever
   `source_id` is non-blank. Falls back to the legacy
   `(account_id, date, amount, raw_description)` tuple otherwise.
2. `Canonical.account_id` accepts a new `portable_ref:` kwarg. When
   present it is the **only** input to the digest — `institution:` is
   intentionally excluded so two providers scraping the same physical
   account collide on the same `acc_<hex>`.

Both are unconditional in the framework: there is no per-provider feature
flag. Each provider must update its normalizer; until then it keeps the
old behavior because it isn't passing the new inputs.

---

## Why this matters

### Transactions

Two upstream debits on the same day, same amount, same description (e.g.
two ING Kepler debits on 2026-05-04 of -680 each, distinct V1ID UUIDs)
used to collapse to one canonical `txn_<hex>`. SimpleFIN clients (Actual,
Sure.am) dedup by `id` per spec, so the second debit was silently dropped
on import. Routing `source_id` through fixes it.

### Accounts

A user who scrapes their ING checking account both via the direct ING
provider and via Fintonic gets two `acc_<hex>` values today. The downstream
merge layer in simplefreen needs them to collide so it can join transactions
across sources. The portable key for Spanish banks is `BANKID:PRODUCTID`
(4-digit CCC bank code + last 4 of the account number). Both pieces are
present in an IBAN and Fintonic already exposes them split out, so the
two providers converge on the same string.

---

## What changed in the framework

### `Freentonic::Canonical.transaction_id`

```ruby
def self.transaction_id(account_id:, date:, amount:, raw_description:,
                        source_id: nil)
```

Behavior:

- If `source_id` is non-blank → hash `(account_id, source_id)`.
- Otherwise → hash `(account_id, date, amount, raw_description)` (legacy).

### `Freentonic::Canonical.account_id`

```ruby
def self.account_id(institution:, portable_ref: nil, iban: nil,
                    source_id: nil, name: nil, stable_ref: nil)
```

Behavior:

- If `portable_ref` is non-blank → hash `[portable_ref]` only. **No
  institution.** This is what makes ING-direct and Fintonic-aggregated
  scrapes of the same account collide.
- Otherwise → previous chain: `(institution, first_non_empty(stable_ref,
  iban, source_id, name))`. Used for cash, brokerage, and aggregator-only
  banks whose `product_id` is opaque.

### `Freentonic::Providers::CanonicalBuilder`

`build_transaction` already accepts `source_id:` — confirm your normalizer
passes it (most do). `build_account` gains two new kwargs:

- `portable_ref:` — feeds the digest. Opaque bytes; "BANKID:PRODUCTID" is
  the convention for Spanish banks, but the framework treats it as an
  arbitrary string.
- `portable_id:` — denormalized human-readable companion that lands on
  the resulting `Canonical::Account` as a first-class field (and in the
  wire JSON under the same name). Not used for hashing. Convention is
  `"bank:BANKID:PRODUCTID"` so logs and downstream tooling can eyeball
  cross-source matches without re-deriving the hash. Pass it whenever
  you pass `portable_ref:`.

The two are kept independent: the framework will not derive one from the
other. Different providers can choose different display strings for the
same physical account; only `portable_ref` has to match for the IDs to
collide.

---

## Per-provider work

### ING — derive portable_ref from IBAN

Spanish IBAN layout: `ES kk BBBB GGGG DD CCCCCCCCCC`

- Bytes 4–7 (0-indexed): 4-digit CCC bank code → `iban[4, 4]`
- Last 4 of the BBAN account number → `iban[-4, 4]`

In the account-building site:

```ruby
portable_ref =
  if iban && iban.length >= 18 && iban.start_with?("ES")
    "#{iban[4, 4]}:#{iban[-4, 4]}"
  end

Builder.build_account(
  institution: INSTITUTION,
  source_id:   raw_account["uuid"],
  currency:    raw_account["currency"],
  name:        raw_account["alias"],
  iban:        iban,
  portable_ref: portable_ref,
  portable_id:  portable_ref && "bank:#{portable_ref}",
  # ...rest unchanged
)
```

Keep passing `iban:` — it stays useful as account metadata even though
it no longer participates in the id derivation when `portable_ref` is set.

For ING accounts that have no IBAN (rare; certain savings products),
leave `portable_ref` nil and let the legacy fallback take over.

### Unicaja — same as ING

Unicaja exposes IBAN identically. Reuse the same `iban[4, 4]` /
`iban[-4, 4]` slicing. If the codebase grows enough Spanish-IBAN providers,
factor a helper into `Freentonic::Providers::Helpers` (`iban_portable_ref(iban)`)
and we'll absorb it into the framework — for now duplicate the 3 lines per
provider, it's not worth the abstraction.

### Fintonic — derive from bank_id + product_id

Fintonic payloads carry the bank code and product id as separate fields.
The mapping rule:

```ruby
portable_ref =
  if raw_account["type"] == "ACCOUNT" &&
     raw_account["fintonic_product_id"].to_s =~ /\A\d{4}\z/
    "#{raw_account['fintonic_bank_id']}:#{raw_account['fintonic_product_id']}"
  end
portable_id = portable_ref && "bank:#{portable_ref}"
```

Pass both into `build_account`. When `portable_ref` is nil (CREDITCARD or
opaque product_id), leave `portable_id` nil too — there's nothing
useful to display for cross-source matching.

**Important constraints:**

- **Only `type: "ACCOUNT"`.** Skip `CREDITCARD` types — those don't have a
  cross-provider equivalent in this scheme.
- **Only when `fintonic_product_id` matches `/\A\d{4}\z/`.** Some banks
  (0232, 2048, and others) return an opaque hash instead of the last-4
  digits; those product_ids do not correspond to anything observable from
  a direct provider, so a portable_ref derived from them would not collide
  with anything. Leave `portable_ref` nil and let the legacy
  `(institution, source_id)` derivation continue to apply.

The `fintonic_bank_id` is itself the 4-digit CCC code, so no transformation
is needed beyond string interpolation.

### Revolut and others

No change. Revolut accounts have no Spanish CCC equivalent and no other
provider scrapes them, so a portable_ref would be cosmetic. Leave alone.
Add when an analogous portable key becomes derivable for any future
provider.

---

## Verification — required tests in each provider repo

Add to each provider's normalizer test file:

### ING / Unicaja

```ruby
def test_account_with_iban_collides_with_fintonic_for_same_physical_account
  # The cross-provider matching contract.
  ing = run_normalizer(account_with_iban: "ES0000000000000000000000").accounts.first

  fintonic_account_id = Freentonic::Canonical.account_id(
    institution: "fintonic",
    portable_ref: "9999:0001"
  )
  assert_equal fintonic_account_id, ing.id
  assert_equal "bank:9999:0001", ing.portable_id
end

def test_account_without_iban_falls_back_to_legacy_derivation
  acct = run_normalizer(account_without_iban: true).accounts.first
  # Same id this provider produced before the portable_ref change.
  assert_equal "acc_<frozen_legacy_hash_here>", acct.id
end
```

### Fintonic

```ruby
def test_regular_account_produces_portable_ref
  acct = run_normalizer(
    type: "ACCOUNT",
    fintonic_bank_id: "1465",
    fintonic_product_id: "1272"
  ).accounts.first
  expected = Freentonic::Canonical.account_id(
    institution: "ing",  # arbitrary — institution is dropped from the digest
    portable_ref: "9999:0001"
  )
  assert_equal expected, acct.id
end

def test_credit_card_does_not_use_portable_ref
  acct = run_normalizer(type: "CREDITCARD",
                       fintonic_bank_id: "1465",
                       fintonic_product_id: "1272").accounts.first
  refute_equal Freentonic::Canonical.account_id(
    institution: "fintonic", portable_ref: "9999:0001"
  ), acct.id
end

def test_opaque_product_id_does_not_use_portable_ref
  acct = run_normalizer(type: "ACCOUNT",
                       fintonic_bank_id: "0232",
                       fintonic_product_id: "a91f8c4e").accounts.first
  # Falls back to (institution, source_id) — old id stable.
  refute_match(/\A.*portable.*\z/, acct.id) # placeholder — pin to actual hash
end
```

### Transactions (all providers)

If your normalizer was already populating `Transaction#source_id` (most
were), the **txn_<hex>** values will change once on the next sync. Add a
single regression test that confirms two transactions with the same
`(date, amount, description)` but distinct `source_id` produce distinct
canonical ids:

```ruby
def test_same_day_duplicate_operations_get_distinct_ids
  txs = run_normalizer(fixture: "two-kepler-debits-2026-05-04.json").transactions
  assert_equal 2, txs.size
  refute_equal txs[0].id, txs[1].id
  refute_equal txs[0].source_id, txs[1].source_id
end
```

If your normalizer was **not** populating `source_id`, add it now —
otherwise this provider stays vulnerable to the original collapse bug for
any same-day duplicate operation.

---

## Rollout coordination

Every provider PR is a breaking change for its downstream consumers
(simplefreen run-canonical store, Actual via SimpleFIN). The first sync
after merge will produce a new set of `acc_<hex>` and (for any provider
that was already setting `source_id`) `txn_<hex>` values, which downstream
treats as brand-new rows. Plan a one-shot reconciliation in Actual at the
moment each provider lands.

Recommended sequence:

1. Merge framework `sync-ids` → tag freentonic gem.
2. Bump the gem pin in each provider repo.
3. Open one PR per provider implementing the normalizer change above.
4. Land providers one at a time, with the user reconciling Actual between
   each — don't batch multiple provider migrations into one Actual reset.
5. Once all targeted providers are migrated, simplefreen can ship the
   merge layer that joins on the now-portable `acc_<hex>`.

If any provider needs to defer (e.g. a user already has months of synced
data they can't reconcile right now), simply don't pass `portable_ref` in
that provider's `build_account` call — the legacy derivation continues to
work. The change is pay-as-you-go per provider.

---

## Out of scope

- **Cross-provider transaction id collision via hashing.** Not happening.
  The merge layer in simplefreen joins on `account_id` and matches
  individual transactions by amount/date proximity. We discussed why
  hash-based txn matching is fragile across upstream description
  variations; the explicit merge layer is the right home for it.
- **Hashing IBANs into portable_ref.** No — providers send the
  `BANKID:PRODUCTID` string directly. Hashing is the framework's job.
- **Normalizing portable_ref shape in the framework.** The framework
  strips whitespace and otherwise treats it as opaque. Providers are
  responsible for emitting `"BANKID:PRODUCTID"` in the agreed shape.
  This keeps the framework locale-agnostic for non-Spanish providers
  whose CCC-equivalent has a different layout.
