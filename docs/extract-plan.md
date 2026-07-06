# Declarative extractor plans (`extract: plan:`)

An extractor turns a captured session into the raw provider payload the
normalizer consumes. For a provider whose extractor is pure
orchestration — call an endpoint, loop over the rows, call another
endpoint per row, assemble a hash — that Ruby can be replaced with a
declarative `extract: plan:` block. No sibling `extractor.rb`, zero
provider Ruby on the extract side.

Endpoints are already declarative (`api_client.endpoints:`, including
offset and cursor pagination). A plan only expresses the *orchestration*
around them.

## When to use a plan (and when not to)

Use `plan:` when the extractor would only:

- call declared `api_client` endpoints,
- loop over a prior response's rows to drive per-row calls,
- pick sub-values out of responses (dig / fallback chain),
- assemble the results into the raw hash.

A plan can also shape the fetched data: coalesce a value from several
sources (`let:` + `coalesce:`), merge arrays (`concat:`), dedupe by a key
or key-fallback chain (`dedup_by:`), build a lookup map (`index_by:`) and
read it back with a runtime key (`lookup:`), and gate a step on a numeric or
presence condition (`when:`). That covers a conditional extended-history
fetch, a cross-endpoint merge/dedup, and a two-list key join without any Ruby.

Keep the `{ruby:, class:}` escape hatch when the extractor needs anything
imperative — a plan **cannot** express these by design:

- `client.raw_request(...)` to endpoints not declared in `api_client:`,
- `client.update_auth_headers!(...)` mid-extraction (e.g. rotating a
  Bearer after an SCA elevation),
- operator-prompt-gated control flow (`remote_prompt_store`),
- per-row coercion, string predicates, or arbitrary arithmetic. A `when:`
  gate speaks only the fixed `when_context` operator set (numeric
  comparisons, equality, presence) over a single binding — not an
  expression language. A classify-and-drop decision that needs string
  matching (Unicaja's credit-vs-debit card split) belongs in the
  normalizer, not the plan.

ING is the canonical escape-hatch provider; Revolut is the canonical
plan provider. If you're unsure, start with Ruby — moving to a plan
later is mechanical.

## The two forms

```yaml
# Escape hatch — a provider Ruby class:
extract:
  ruby: ./extractor.rb
  class: My::Provider::Extractor

# Declarative — a plan:
extract:
  plan:
    steps: [ ... ]
    output: { ... }
```

They are mutually exclusive; declaring both is a load-time error.

## Worked example (Revolut)

```yaml
extract:
  plan:
    steps:
      - fetch: fetch_wallet
        as: wallet

      - select: { from: wallet, path: pockets, default: [] }
        as: pockets

      - for_each:
          source: pockets
          pluck: currency        # xs.map { |x| x["currency"] }
          compact: true          #   .compact
          uniq: true             #   .uniq
        as_item: currency
        as: bank_details         # collect: array (default)
        do:
          - fetch: fetch_bank_details
            args: { currency: "{currency}" }
            as: detail
            safe: true           # tolerate a per-item failure → nil
          - yield: { currency: "{currency}", details: "{detail}" }
            skip_if_nil: detail  # drop the iteration when detail is nil

      - fetch: fetch_cards
        as: cards
        safe: true

      - fetch: fetch_vaults
        as: vaults
        safe: true

      - for_each:
          source: pockets
        as_item: pocket
        as: pocket_transactions
        collect: map             # a Hash instead of an Array
        key: "{pocket.id}"
        do:
          - fetch: fetch_pocket_transactions
            args: { pocket_id: "{pocket.id}", from_ms: "{from_ms}", now_ms: "{now_ms}" }
            as: txns
            safe: true
            default: []
          - yield: "{txns}"

    output:
      wallet: "{wallet}"
      pockets: "{pockets}"
      bank_details: "{bank_details}"
      cards: "{cards}"
      vaults: "{vaults}"
      pocket_transactions: "{pocket_transactions}"
```

## Reference

### Bindings and templates

A plan runs against a flat scope of named bindings. A string value is a
**token** only if it is exactly `{name}` or `{name.dotted.path}` —
everything else (including numbers, booleans, and strings that merely
contain braces) is a literal and passes through unchanged. Hashes and
arrays in `args:`, `yield:`, and `output:` are resolved recursively.

`{name.a.b}` digs into a bound Hash (nil at the first missing/non-Hash
segment). This is the same whole-token rule the `api_client` param DSL
uses, plus the dotted path.

Five bindings are pre-seeded before the first step:

| Binding | Value |
| --- | --- |
| `from_date` | the resolved lookback start (`Date`) |
| `from_ms` | `from_date` as epoch milliseconds |
| `now_ms` | now, epoch milliseconds |
| `today` | today (`Date`) — for `days_ago:` arithmetic and end-of-range defaults |
| `lookback_days` | `today - from_date` in days — the figure `when:` gates a `>N` extended-history fetch on |

Every `as:` adds a binding. Loop variables (`as_item:`) are visible only
inside that `for_each`'s `do:` block.

Date formatting stays on the endpoint: pass a `Date` binding as an `arg:`
and let the endpoint's `{name|iso}` / `{name|date}` param filter format it
(see the `api_client` DSL). The plan doesn't re-implement date filters.

### Steps

**`fetch: <endpoint>`** — call a declared `api_client` endpoint.

| Key | Meaning |
| --- | --- |
| `fetch` | endpoint name — **must** appear in `api_client.endpoints` |
| `args` | kwargs passed to the endpoint (templates resolved first) |
| `as` | bind the result |
| `safe` | `true` → rescue an API error to `default:` (or nil) with an stderr note |
| `default` | value to bind when a `safe:`/`on_error: warn` fetch fails |
| `on_error` | `{ abort: "msg" }` or `{ warn: "msg" }` — a custom failure policy (see below) |
| `extract_batch` | list of keys to unwrap a hash-wrapped array (`Hash` → first matching key) |

`safe:` never swallows a `SessionExpired` (401/403) — that always
propagates so the Extract stage can re-wrap it as an actionable "re-run
connect" error. Use `safe:` for non-critical products, not to mask a dead
session.

**`on_error:`** overrides that default for a *critical* fetch, covering
`SessionExpired` too. `{ abort: "msg" }` raises a `UserError` with your
operator message on any failure — for a fetch whose silent failure would
mislead downstream (an empty `/position-keeping` reads as "all accounts
deleted"). `{ warn: "msg" }` notes the message on stderr and degrades to
`default:` (or nil). `on_error:` and `safe:` are alternatives — `on_error`
takes precedence.

**`select: { from:, path:, default: }`** — dig a sub-value out of a bound
result. `path` is a single key, a dotted path (`meta.region`), or a list
(fallback chain — first non-nil wins). An integer path segment indexes an
Array (`accessTokens.0.accessToken`). `default:` applies when the lookup
is nil. Binds via `as:`.

**`for_each:`** — iterate a bound collection.

| Key | Meaning |
| --- | --- |
| `for_each.source` | a bound collection name |
| `for_each.pluck` | pluck this field from each element first |
| `for_each.compact` | drop nils |
| `for_each.uniq` | dedupe |
| `as_item` | the loop-variable binding name |
| `do` | sub-steps run per iteration (in a child scope) |
| `as` | bind the collected result |
| `collect` | `array` (default) or `map` |
| `key` | map-key template (required when `collect: map`) |

Each iteration's `yield:` is what gets collected. Ordinary `fetch:` /
`select:` steps may appear in `do:` before the `yield:`.

**`yield: <value>`** (inside `for_each.do` only) — the value collected
for this iteration. `skip_if_nil: <binding>` drops the iteration when that
binding is nil.

### Data-shaping verbs

**`let: <name>`** — bind `<name>` to a computed value. Exactly one source:

| Source | Meaning |
| --- | --- |
| `value:` | a resolved template (`{token}`, literal, number, nested hash/array) |
| `coalesce:` | an ordered list of templates — first whose value is non-nil wins (the declarative `a \|\| b \|\| "literal"`) |
| `days_ago:` | an integer `N` → `today - N` (a `Date`), for lookback-window arithmetic |

```yaml
- let: begin_date
  coalesce: ["{from_date}", "{date_range.olderTransactionUserDate}", "2015-01-01"]
- let: recent_from
  days_ago: 30
```

**`concat: [name, …]`** — bind `as:` to the concatenation of the named
bound collections. Each name is `Array()`-coerced, so an unbound name — a
fetch whose `when:` gate skipped it — contributes `[]`. This is the
structured `a + b` / `txs.concat(more)`.

```yaml
- concat: [old_movements, recent_movements]
  as: merged
```

**`dedup_by: key | [key, …]`** — bind `as:` to `from:` with duplicate rows
removed, keeping the **first** occurrence of each key. A single field, or
a fallback list (first non-nil field value is the key). A row whose key
resolves to **nil is always kept** — never deduped — so a record missing
the sequence field passes through instead of collapsing rows together.

```yaml
- dedup_by: [numMovimiento, nummov]   # cross-endpoint field spellings
  from: merged
  as: movements
```

### Lookup, routing, and guard verbs

**`index_by: { from:, key:, value: }`** — build a `Hash` from a bound list
by extracting a key and value from each item. Binds via `as:`. `key:` and
`value:` are each either a dotted-path String (`uuid`) or a *find-by-field*
spec: `{ path:, where:, pick: }` — dig `path` to a list, find the element
whose fields all match `where`, then `pick` a field from it. Entries with a
nil key or a nil/blank value are dropped (a missing identifier must not
create a `nil => nil` mapping).

```yaml
# V1ID → v2 UUID from a products[].identifiers[] list
- index_by:
    from: products
    key:   { path: identifiers, where: { type: LOCAL_UUID }, pick: value }
    value: { path: identifiers, where: { type: UUID },       pick: value }
  as: uuid_map
```

**`lookup: { from:, key:, default? }`** — the inverse of `index_by:`: read
a bound map with a *runtime-resolved* key. `from:` names a `Hash` built by
an earlier step; `key:` is a value template (`{product.uuid}`) resolved
against the current scope, so inside a `for_each` the same step reads a
different entry each iteration. Binds via `as:`. A missing key — or an
unbound / non-`Hash` `from:` — binds `default:` when given, else `nil`, so a
downstream `skip_when:`/`warn:` can route on the absent value. This is the
one idiom that joins two lists keyed differently — e.g. legacy products
(carrying `type`) against modern products (carrying identifiers). It only
digs an already-built binding; it computes nothing.

```yaml
# join each legacy product to its v2 UUID via the map index_by: built
- for_each: { source: products }
  as_item: product
  do:
    - lookup: { from: uuid_map, key: "{product.uuid}" }
      as: v2_uuid
    - warn: "no v2 UUID for {product.uuid}; skipping"
      when: { v2_uuid: { absent: true } }
    - skip_when: { v2_uuid: { absent: true } }
    - yield: { uuid: "{v2_uuid}", alias: "{product.alias}" }
  as: joined
```

**`apply: <function>`** — invoke a registered **pure function** from the
`Freentonic::Fn` registry with `args:`, binding the result via `as:`
(required). The registry is the whitelist — exactly the declared-endpoint
pattern `fetch:` uses — and every function is pure by contract *and*
enforcement: args in → value out, no I/O, no client, no clock, and the
interpreter deep-freezes the resolved args so a mutating impl raises
instead of corrupting a shared binding. Because `args:` is a literal YAML
hash, parameter names are checked at load time: an unknown function, an
undeclared parameter, or a missing required parameter fails `--lint`, not
a live sync. See `docs/pure-functions-plan.md` for the registry design and
the builtin catalog (`cents`, `parse_date`, `map_status`, `pick`,
`build_account`, `build_transaction`, …).

```yaml
- for_each: { source: movements }
  as_item: mv
  do:
    - apply: cents
      args: { amount: "{mv.amount}" }
      as: amount_cents
    - skip_when: { amount_cents: { absent: true } }
    - yield: { id: "{mv.uuid}", cents: "{amount_cents}" }
  as: rows
```

**`note: <msg>` / `warn: <msg>` / `abort: <msg>`** — emit an operator
breadcrumb: `note` to stdout, `warn` to stderr, `abort` raises a
`UserError`. The message embeds `{tokens}` (resolved against the current
scope). Each may carry a `when:` gate, so a preflight guard is just an
`abort`/`warn` behind a condition:

```yaml
- abort: "no Bearer captured — re-run connect"
  when: { bearer: { absent: true } }
- warn: "XSRF-TOKEN cookie missing; state-changing calls may 200-with-empty"
  when: { xsrf: { absent: true } }
```

**`skip_when: <gate>`** (inside `for_each.do` only) — drop the current
iteration (a declarative `next`) when the gate passes; it contributes
nothing to the collected result and short-circuits the rest of the
iteration. Pair it with a `warn:`/`note:` so a skip stays visible:

```yaml
do:
  - select: { from: product, path: kind }
    as: kind
  - warn: "skipping {product.alias} (kind=investment): poisons the batch"
    when: { kind: { eq: investment } }
  - skip_when: { kind: { eq: investment } }
  - yield: { product: "{product}" }
```

### `when:` — gating a step

Any step may carry a `when:` gate. When the condition is false the step is
a no-op: it neither fetches nor binds, so a later `concat:`/reference to
its `as:` reads `[]`/nil. The grammar is the workflow's `when_context`
operator set, over a single binding:

```yaml
- fetch: fetch_extended_account_movements
  args: { ppp: "{ppp}", fecha_desde: "{from_date}", fecha_hasta: "{recent_from}" }
  as: old
  safe: true
  when: { lookback_days: { gt: 30 } }   # only fetch older history on long runs
```

Operators: `gt` / `gte` / `lt` / `lte` (numeric operand), `eq` / `neq`,
`present` / `absent` (boolean operand) — identical to browser-phase
`when_context:`. A gate over a non-numeric binding with a numeric operator
raises. It is **not** an expression language: no string matching, no
arithmetic, one binding per key.

### `output`

A hash mapping raw-payload keys to templates, assembled after all steps
run. This is the return value handed to the normalizer as `context[:raw]`.

## Validation

Plans are fully statically checkable — `freentonic --lint` (and workflow
load) verifies, with no Chrome and no network:

- exactly one of `plan:` / (`ruby:` + `class:`),
- every `fetch:` names a declared endpoint,
- every `apply:` names a registered function, with no unknown and no
  missing required parameters,
- every `{token}` root and every `select.from` / `for_each.source` /
  `concat:` name / `dedup_by.from` / `index_by.from` / `lookup.from` /
  `when:` key references a name bound earlier (loop variables scoped to
  their `do:`),
- step shapes are well-formed and every verb is known,
- each `for_each` contains a `yield:`,
- each `let:` declares exactly one of `value:` / `coalesce:` / `days_ago:`,
- each `when:` uses only known operators with correctly-typed operands.

A typo'd endpoint or a dangling binding fails before login, not after.

## Security note

The interpreter dispatches on a fixed, closed verb set, and `fetch:`
resolves only against the workflow's own declared endpoint names — it
never calls an arbitrary client method. A plan therefore cannot reach
`raw_request`, `update_auth_headers!`, or any Ruby outside the declared
endpoints. Declarative plans are strictly less powerful, and strictly
safer, than the Ruby escape hatch.
