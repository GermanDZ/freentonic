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

Keep the `{ruby:, class:}` escape hatch when the extractor needs anything
imperative — a plan **cannot** express these by design:

- `client.raw_request(...)` to endpoints not declared in `api_client:`,
- `client.update_auth_headers!(...)` mid-extraction (e.g. rotating a
  Bearer after an SCA elevation),
- operator-prompt-gated control flow (`remote_prompt_store`),
- per-row coercion, arithmetic, or arbitrary conditionals.

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

Three bindings are pre-seeded before the first step:

| Binding | Value |
| --- | --- |
| `from_date` | the resolved lookback start (`Date`) |
| `from_ms` | `from_date` as epoch milliseconds |
| `now_ms` | now, epoch milliseconds |

Every `as:` adds a binding. Loop variables (`as_item:`) are visible only
inside that `for_each`'s `do:` block.

### Steps

**`fetch: <endpoint>`** — call a declared `api_client` endpoint.

| Key | Meaning |
| --- | --- |
| `fetch` | endpoint name — **must** appear in `api_client.endpoints` |
| `args` | kwargs passed to the endpoint (templates resolved first) |
| `as` | bind the result |
| `safe` | `true` → rescue an API error to `default:` (or nil) with an stderr note |
| `default` | value to bind when a `safe:` fetch fails |
| `extract_batch` | list of keys to unwrap a hash-wrapped array (`Hash` → first matching key) |

`safe:` never swallows a `SessionExpired` (401/403) — that always
propagates so the Extract stage can re-wrap it as an actionable "re-run
connect" error. Use `safe:` for non-critical products, not to mask a dead
session.

**`select: { from:, path:, default: }`** — dig a sub-value out of a bound
result. `path` is a single key, a dotted path (`meta.region`), or a list
(fallback chain — first non-nil wins). `default:` applies when the lookup
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

### `output`

A hash mapping raw-payload keys to templates, assembled after all steps
run. This is the return value handed to the normalizer as `context[:raw]`.

## Validation

Plans are fully statically checkable — `freentonic --lint` (and workflow
load) verifies, with no Chrome and no network:

- exactly one of `plan:` / (`ruby:` + `class:`),
- every `fetch:` names a declared endpoint,
- every `{token}` root and every `select.from` / `for_each.source`
  references a name bound earlier (loop variables scoped to their `do:`),
- step shapes are well-formed and every verb is known,
- each `for_each` contains a `yield:`.

A typo'd endpoint or a dangling binding fails before login, not after.

## Security note

The interpreter dispatches on a fixed, closed verb set, and `fetch:`
resolves only against the workflow's own declared endpoint names — it
never calls an arbitrary client method. A plan therefore cannot reach
`raw_request`, `update_auth_headers!`, or any Ruby outside the declared
endpoints. Declarative plans are strictly less powerful, and strictly
safer, than the Ruby escape hatch.
