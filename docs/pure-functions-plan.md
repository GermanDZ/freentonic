# Pure Functions (`apply:`) + Declarative Normalize Plans — Plan

Status: PROPOSED (Asks 7–10)
Prereqs: extract plans (v0.13), lookup verb (v0.14) — shipped.

## Goal

Delete every per-provider `normalizer.rb` (1,143 lines across ING /
Unicaja / Fintonic / Revolut) and replace it with a declarative
`normalize: plan:` that composes **framework-owned pure functions**.
After this program:

- **Pure**: every function is `args in → value out`. No I/O, no client,
  no clock, no randomness, no mutation of inputs. Enforced by harness,
  not convention.
- **Isolated**: functions receive only their resolved args — never the
  scope, the api_client, credentials, or the workflow context. The
  registry is closed at runtime: only functions compiled into the
  freentonic gem exist. **Zero provider-authored code executes during a
  sync.**
- **Extensible**: adding a function is one registration in freentonic
  (definition + examples + tests); every plan context can call it the
  moment it exists.
- **Invocable anywhere**: one `apply:` verb added to the *shared* plan
  step grammar, so the same function works in `extract: plan:`, the
  `elevate:` phase, the new `normalize: plan:`, and any future
  plan-shaped context, with no per-context plumbing.

## Non-goals

- Provider-shipped functions (JS/WASM/sandboxed Ruby). The registry is
  freentonic-owned; provider-specific needs land as *parameterized
  generic* functions via freentonic PRs. Revisit only if third-party
  untrusted providers ever become a goal.
- A general-purpose expression language. The verb set stays closed;
  anything algorithmic is a named, tested function — never inline logic
  in YAML.

## Design

### 1. The `Fn` registry (`Freentonic::Fn`)

```ruby
Freentonic::Fn.define "collapse_prefix_dups" do |f|
  f.description "Drop pre-clearing dup rows: within each group, keep " \
                "only the longest row when every shorter row's text is " \
                "a strict prefix of it (whitespace-normalized)."
  f.param :rows,     :array,  required: true
  f.param :group_by, :array,  required: true   # field names
  f.param :text,     :string, required: true   # field holding the text
  f.example args: { rows: [...], group_by: %w[account_id date amount], text: "description" },
            returns: [...]
  f.impl do |rows:, group_by:, text:|
    # pure Ruby, operates only on args
  end
end
```

- `Fn.define` registers into a frozen-at-boot name→function map.
  Duplicate names raise at load. `Fn.names` is the whitelist the schema
  validator checks `apply:` against — the exact same pattern as
  `api_client_endpoint_names` for `fetch:`.
- **Every function MUST declare at least one `example`.** The registry
  test suite iterates all functions and runs every example through the
  purity harness (below). A function without examples fails CI — this
  is the extensibility guarantee: you cannot add a function without
  making it self-testing.
- Params carry a light type tag (`:array`, `:hash`, `:string`,
  `:integer`, `:boolean`, `:any`) checked at call time with a clear
  operator error; `required:`/`default:` handled by the registry so
  impls never see missing keys.
- Determinism rule: functions never read the clock. Anything
  time-anchored takes a date/timestamp arg — plans already seed
  `today` / `now_ms` / `from_date`, so the plan passes them explicitly.

### 2. The `apply:` verb (shared step grammar)

```yaml
- apply: collapse_prefix_dups
  args:
    rows: "{transactions}"
    group_by: [account_id, date, amount]
    text: description
  as: transactions
```

- Added to `PLAN_STEP_VERBS` in `workflow_schema.rb` + a
  `do_apply` branch in `ExtractPlan::Interpreter#dispatch` → available
  in extract plans, elevate steps, for_each `do:` blocks, and normalize
  plans for free (elevate inherits via the interpreter subclass;
  validation flows through `validate_plan_step!`).
- Static validation at workflow load (same rigor as `fetch:`):
  - function name must exist in `Fn.names`;
  - `args:` keys ⊆ declared params; all `required:` params present;
  - whole-token `{refs}` in args must be bound (reuses
    `validate_plan_refs!`);
  - `as:` required and non-empty (a pure function whose result isn't
    bound is dead code — reject it).
- Runtime: `scope.resolve(args)` → `Fn.call(name, args)` → deep-freeze
  the resolved args before the call (cheap insurance: an impl that
  mutates its input raises immediately, in production too) →
  `scope.bind(as, result)`. Never `send` off YAML input — dispatch is
  a registry hash lookup.

### 3. `normalize: plan:`

The `normalize:` key grows a plan form, mutually exclusive with the
`ruby:`/`class:` escape hatch (which Ask 10 deletes):

```yaml
normalize:
  plan:
    steps: [...]
    output:
      accounts:     "{accounts}"
      transactions: "{transactions}"
      liabilities:  "{liabilities}"   # optional
```

- **Execution**: `Stages::Normalize` runs the same
  `ExtractPlan::Interpreter` with `client: nil` and a verb set that
  excludes `fetch:` (validator + interpreter both parameterized by an
  allowed-verbs list — one mechanism, reused by elevate which already
  extends it). A normalize plan is therefore a *total, offline*
  computation: raw in, canonical out, replayable via `--from-raw`
  forever.
- **Seeded scope**: `raw` (the extract payload), `config` (the
  provider's `config.yml` — so `STATUS_MAP`, `KIND_BY_TYPE`,
  `FIELD_ALIASES`, `INSTITUTION`, `SCRAPER_VERSION` resolve as
  `{config.status_map}` etc.), plus the standard seed bindings
  (`today`, …).
- **Output contract**: `output:` binds `accounts` / `transactions` /
  optional `liabilities`; the stage calls
  `CanonicalBuilder.payload(..., scraper_version: config)` itself.
  Plans never assemble the envelope.
- **Builders are just functions**: `build_account`,
  `build_transaction`, `build_liability`, `map_status`,
  `cents_to_amount`, `spanish_iban_portable_keys`,
  `card_pan_portable_keys` register as `Fn`s wrapping the existing
  (already-tested) `CanonicalBuilder` / `Helpers` methods. Entity
  structs serialize through scope/output untouched.

### 4. Seed function set

Tier A — wrappers over existing tested code (freentonic already owns
the logic; registration + examples only):

`cents`, `cents_to_amount`, `parse_date`, `parse_timestamp_ms`,
`map_status`, `pick` (alias-aware field read), `extract_fields`,
`first_present`, `pan_last4`, `compact_whitespace`,
`spanish_iban_portable_keys`, `card_pan_portable_keys`,
`build_account`, `build_transaction`, `build_liability`.

Tier B — new generic algorithms, extracted from the normalizers'
provider-specific tails (each is a *parameterized* generalization, not
an ING/Fintonic special case):

| Function | Generalizes | Used by |
|---|---|---|
| `group_by` | rows → map keyed by field(s) / key template | Fintonic (by product), ING (cc lines) |
| `tree_paths` | hierarchy `{id => {name:, ancestors:}}` → `{id => "A/B/C"}` | Fintonic category tree |
| `collapse_prefix_dups` | drop rows whose text is a strict prefix of a groupmate's | ING pre-clearing dups |
| `distribute_group_balance` | per-group total → per-member amounts (member field first; carrier fallback with priority spec) | ING per-plastic cc balances |
| `remap_fields` | marker-gated field mapping (rows matching `when_has:` reshaped per `map:` spec) | ING v2-search → legacy shape |

The gap analysis per provider (from reading all four normalizers):
**Revolut** and **Unicaja** are Tier A + `for_each`/`index_by` only.
**Fintonic** adds `group_by` + `tree_paths`. **ING** needs all of
Tier B — it is the migration stress test and goes last.

Everything else in the current normalizers (guard-and-skip rows missing
id/amount/date, coalescing descriptions, metadata assembly) is already
expressible with shipped verbs: `for_each` + `skip_when` + `let
coalesce:` + `lookup` + `index_by`.

## Phasing

Sequenced so both repos stay green at every merge; the `ruby:` escape
hatch coexists during migration and is deleted at the end (sequencing,
not back-compat hedging).

**Ask 7 (freentonic v0.15.0) — Fn core.**
`Freentonic::Fn` registry + definition DSL + purity harness; `apply:`
verb in shared grammar (validator + interpreter); Tier A functions
registered; `--lint` validates `apply:` offline. No provider changes.

**Ask 8 (freentonic v0.16.0) — `normalize: plan:`.**
Verb-set parameterization (fetch excluded offline), seeded scope
(`raw`/`config`), output contract, stage wiring, linter support.
Proof: migrate **Revolut** in freentonic-providers (golden parity
protocol below), delete `revolut/normalizer.rb`.

**Ask 9 (freentonic v0.17.0) — Tier B algorithms.**
`group_by`, `tree_paths`, `collapse_prefix_dups`,
`distribute_group_balance`, `remap_fields` — each with table-driven
unit tests porting the edge cases the ING/Fintonic normalizer tests
encode today. Migrate **Fintonic**, **Unicaja**, then **ING**; delete
their normalizer.rb files.

**Ask 10 (freentonic v0.18.0) — burn the boats.**
Delete the `normalize: ruby:/class:` escape hatch, `NormalizerBase`,
and the scaffold's normalizer.rb template (scaffold emits a plan
skeleton instead). Providers repo is YAML + config + tests only.

## Testing strategy

Six layers, from function to fleet:

**L1 — Purity harness (automatic, registry-driven).** One test file
iterates `Fn.all`; for every declared example it: deep-freezes the args
(recursive freeze — any mutation raises), calls the function **twice**,
asserts both results equal each other and the declared `returns:`, and
asserts the args are structurally unchanged. Because examples are
mandatory, every future function is born covered — a new `Fn.define`
with no example or an impure impl fails CI with zero new test code.

**L2 — Algorithm unit tests (hand-written, Tier B).** Table-driven
edge cases ported from today's normalizer tests so the encoded incident
history survives as executable checks: real twins kept vs prefix dups
collapsed vs mid-string divergence kept (`collapse_prefix_dups`);
carrier fallback ordering, nil-limit lines, zero-purchase lines
(`distribute_group_balance`); root-ancestor exclusion (`tree_paths`).

**L3 — Grammar tests (`workflow_schema`).** `apply:` with unknown
function / missing required arg / undeclared arg / unbound `{ref}` /
missing `as:` each raise a precise `UserError` at load; `fetch:` inside
`normalize: plan:` rejected; `apply:` accepted in extract plans,
elevate steps, and `for_each do:` blocks; `plan:` + `ruby:` together
rejected.

**L4 — Interpreter tests.** Mini normalize plans over inline raw
hashes: seeded `raw`/`config` resolution, builder-function calls
producing canonical entities, `when:`-gated `apply:`, frozen-args
enforcement at runtime.

**L5 — Golden parity (freentonic-providers, per provider — the
migration gate).** Protocol, per provider, in this order:
1. *Before touching anything*: a rake task runs the current
   `normalizer.rb` over every raw fixture the provider's tests own and
   snapshots the canonical payload to `test/golden/<fixture>.json`
   (canonical ids are deterministic, so deep equality is exact).
2. Write the `normalize: plan:` alongside the still-live normalizer.
3. Parity test: plan output deep-equals every golden file. Existing
   behavior tests (per-leg ids, `userDate` vs bank date, pocket-IBAN
   suppression, cc multi-count) are pointed at the plan path and must
   stay green — they are the incident history.
4. Only when green: delete `normalizer.rb`, keep the goldens and the
   parity test as the permanent regression net.
5. Port each load-bearing normalizer comment to a YAML comment on the
   step that owns it (review-blocking checklist item in the migration
   PR).

**L6 — Lint + CI.** `--lint` statically validates every plan
(functions exist, args well-formed, refs bound) with no network and no
provider Ruby; providers CI runs `rake test` per provider; freentonic
CI runs L1–L4. A freentonic version bump that removes/renames a
function fails providers CI at lint time, not at sync time.

## Future extensions (explicitly deferred)

- `apply` as a browser-phase *action* (transform captured
  context values, e.g. derive a header). Cheap later: registry and
  validation are shared.
- A `map:` sugar verb (`for_each` + single `apply` collapse) if
  normalize plans prove verbose in practice.
- Provider-shipped sandboxed functions (QuickJS/WASM) — only if
  third-party providers become real. The `apply:` seam is where they'd
  plug in; nothing in this design forecloses it.
