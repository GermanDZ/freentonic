# Ask 9 — Tier B algorithm scoping

Working notes for the five Tier B `apply:` functions (freentonic
v0.18.0 — the label in `pure-functions-plan.md` still says v0.17.0, which
is now spent; see the version-drift note there). Each is a *parameterized*
generalization lifted from a provider normalizer's tail, registered in
`Freentonic::Fn`, born covered by the purity harness (frozen args, called
twice, identical result), and table-tested against the edge cases the
provider normalizer tests pin today.

Source of truth read for this scope:
`freentonic-providers/{fintonic,ing}/normalizer.rb` and their
`test/*_normalizer_test.rb`.

## Scope change (2026-07-06): dual-mode is permanent; Ask 9 is ING-only

Directive from the owner: **`normalize:`/`extract:` ruby vs declarative is a
permanent, blessed authoring mode — not a migration bridge.** Providers may
run custom Ruby *or* a pure declarative plan, indefinitely, per stage.

This already exists and is first-class — `Normalizers::Builder.build` and
`stages/extract.rb` dispatch on the spec (`plan:` → declarative;
`ruby:`+`class:` → provider Ruby; absent → passthrough). ING already mixes
them: `extract: plan:` + `normalize: ruby:`. So there is **no new "mode"
machinery to build** — the work is a *decision*, not code (see below).

Consequences:
- **Ask 10 ("burn the boats") is cancelled.** Do NOT delete the
  `normalize: ruby:/class:` escape hatch, `NormalizerBase`, or the scaffold's
  normalizer template. Re-document them as supported, not deprecated
  (`normalize-plan.md` still says "escape hatch (deleted in Ask 10)" — fix).
- **Fintonic migrates LAST, or never.** It may be deprecated or left on
  Ruby permanently. So `group_by` + `tree_paths` — which exist *only* to
  unlock Fintonic — drop off the Ask 9 critical path. Keep their specs below
  as ready-to-build-if/when, but don't build them for Ask 9.
- **Ask 9 = ING only.** Migrate `ing/normalizer.rb` to a plan (the one
  provider whose Ruby is worth retiring now). That needs
  `collapse_prefix_dups` + `remap_fields` (+ small leaves) + the `PathDig`
  prereq. `distribute_group_balance` stays cut.

## Migration unlock map

| Function | Generalizes | For | Ask 9? |
|---|---|---|---|
| `collapse_prefix_dups` | drop rows whose text is a strict prefix of a groupmate's | ING | **yes** |
| `remap_fields` | marker-gated row reshape | ING | **yes** |
| ~~`distribute_group_balance`~~ | ~~per-group total → per-member amounts~~ | ~~ING~~ | **CUT** (dead branch, §4) |
| `group_by` | rows → groups keyed by field(s) | Fintonic | deferred (Fintonic last/never) |
| `tree_paths` | `{id => node}` hierarchy → `{id => "A/B/C"}` | Fintonic | deferred (Fintonic last/never) |

- **Unicaja** DOES have a `normalizer.rb` running ruby normalize today
  (corrects an earlier note). It needs **no Tier B** (Tier A +
  `for_each`/`index_by` only), so it can migrate to a plan with existing
  builtins — worth doing alongside Ask 9 to shrink the ruby footprint,
  even though it needs no new functions.
- **Fintonic** specs (`group_by`, `tree_paths`) are retained below as
  reference; they are NOT Ask 9 deliverables under the new plan.

### Deployment reality (drives the Ask 10 gate below)

| Provider | extract | normalize | runs in default declarative-only mode? |
|---|---|---|---|
| Revolut | plan | plan | ✅ yes (today) |
| ING | plan | ruby | ❌ until Ask 9 migrates its normalizer |
| Unicaja | plan | ruby | ❌ until its (Tier-A-only) normalizer migrates |
| Fintonic | plan | ruby | ❌ stays ruby — last/never |

`api_client` ext ruby (the third ruby hatch) is used by **no** provider —
latent, but still gated. Net: after ING + Unicaja migrate, **Fintonic is
the sole reason to enable ruby mode** in production.

## Unicaja migration (real-data-audited 2026-07-06) — NOT Tier-A-only

Correcting the plan doc's "Unicaja = Tier A only": its `normalizer.rb` has
ops no builtin expresses. Audited against a live profile (112 txns,
`simplefreen` UNICAJAGDZ canonical output):

- **`movement_id` SHA1 fallback → DEAD** (0/112 txns; every movement has
  `numMovimiento`). Drop it — no hash function needed. Use
  `pick(:movement_id)` + `skip_when absent`, like ING's uuid.
- **`extract_card_balance_cents` = `(limite − disponible)×100` → LIVE.**
  A real subtraction. Needs a numeric **`subtract`** leaf (a−b), then
  `cents`. (This is the shape ING's cut `line_outstanding` had — dead for
  ING, live for Unicaja.)
- **card balance negation → `negate` leaf** (shared with ING).
- **`credit_card?` string-match filter → RESOLVED to equality-only
  (option A), confirmed by a real listatarjetas dump (2026-07-06).** Two
  cards: credit = `codtipotarjeta:"2"` ("MASTERCARD CLASSIC"), debit =
  `codtipotarjeta:"1"` ("MC DÉBITO DIFERIDO"). `codtipotarjeta=="2"`
  classifies both correctly; the debit text contains no "créd"/"credit"
  so the string fallback never fires. **Drop the fallback; gate on
  `codtipotarjeta=="2"`. No `text_matches` fn needed for cards.**
- **`detect_loan_type` string fallback → RESOLVED to equality-only,
  confirmed by a real listaprestamos dump (2026-07-06).** Loan has
  `indPrestamoHipotecario:"S"` → mortgage by equality (fires before the
  string fallback). Notably `descripcion:"PR. LIBRES"` (says *free* loan)
  while the flag says mortgage — the flag is authoritative, so equality is
  strictly better than the description string-match anyway. **Gate on
  `indPrestamoHipotecario=="S"`; drop the "hipot" fallback.**

**Net: Unicaja needs NO string-classification fn. New-function set is just
`negate` + `subtract`** (both trivial) + existing Tier A. Fully unblocked.
- **CC balance (real data): limite 3000 − disponible 2200 = 800 outstanding
  → −800.00.** Confirms `subtract` + `negate` + `cents` is the live path.
  (Aside: `infoSaldos.consumidoCredito`/`pagadoMesActual` both read 0.00 —
  reproduce the current ruby limite−disponible verbatim for parity, don't
  "fix" the discrepancy.)

Unicaja new-function set: `negate`, `subtract`, + the string-classification
resolution. Everything else is existing Tier A + `for_each`/`lookup`.

### Design fork — string classification in a declarative plan

The normalize-plan grammar deliberately bars string matching from `when:`
gates (numeric/equality/presence only). Options for Unicaja's two
string-match filters:

- **(A, recommended) equality-only + real-data proof.** Drop the string
  fallbacks; gate on `codtipotarjeta=="2"` / `indPrestamoHipotecario=="S"`
  alone. Needs a fuller raw dump (incl. debit cards) to prove no credit
  card is missed. Simplest; zero new capability. Risk: a card typed
  differently silently misclassifies.
- **(B) string-predicate `apply:` function.** Keep gates equality/presence
  only, but add a pure `text_matches(value, any_of:, case_insensitive:)`
  → boolean the plan binds, then `skip_when` reads that boolean. Preserves
  current behavior exactly; expands the *function* surface (not the gate
  grammar) with string logic. More faithful, one more function.
- (C) leave Unicaja on ruby — rejected (defeats "plan only").

## Ask 10 (revised) — provider-Ruby capability gate — ✅ SHIPPED

Implemented: `Freentonic::RubyCapability` (env `FREENTONIC_ALLOW_PROVIDER_RUBY`,
default off = declarative-only). Gate fires in `Engine#run` before any stage
builds, precise to the planned stages (`schema.{extract,normalize}_uses_ruby?`
/ `api_client_uses_ruby?`). `--lint` stays mode-agnostic + emits an `ℹ` note.
Covered by `test/ruby_capability_test.rb` + a linter-note test; the example
integration test opts in. Design notes below.


Replaces "burn the boats." Instead of deleting the ruby hatch, **gate it
behind an explicit operator opt-in**. Default = declarative-only, which
makes "no provider-authored code runs during a sync" a *runtime-enforced*
invariant, not just a per-workflow convention.

**Env gate.** `FREENTONIC_ALLOW_PROVIDER_RUBY=1` (name TBD) enables provider
ruby. Unset/other → declarative-only.

**Three load points to gate** (all funnel through
`PathConfinement.resolve_within!` + `require` + `const_get`):
- `stages/extract.rb:105` — `extract: ruby:/class:`
- `normalizers/builder.rb:29` — `normalize: ruby:/class:`
- `workflow_schema.rb:252` — `api_client` ext ruby

Add `Freentonic::RubyCapability.ensure_enabled!(feature:)` immediately
before each `require` (explicit at each site — capability is a distinct
concern from `PathConfinement`'s path-safety, so don't bury it there).

**Fail fast at LOAD, not mid-sync.** When a workflow declaring ruby is
loaded on a declarative-only server, raise a clear `UserError` naming the
stage + the env var — before Chrome launches, before any fetch. A sync must
never die halfway because it hit a ruby normalizer.

**`--lint` stays mode-agnostic + informational.** Linting is an authoring
tool: it fully validates ruby workflows (loads the class as today) but
emits a note — "uses provider Ruby (normalize.ruby) → requires
FREENTONIC_ALLOW_PROVIDER_RUBY at runtime" — so an operator gets a
pre-deploy signal of "will this run on our default server?" The gate is a
*runtime-execution* concern; `--lint` never enforces it.

Open decisions: (1) env var name + shape (boolean `=1` vs a `mode=` string);
(2) confirm fail-at-load vs fail-at-run; (3) `--lint` informational vs
enforcing. Recommendations above.

## Real-data findings (dead-code audit)

Before generalizing an ING branch, check it's actually reachable under the
**current** `/search`-based extract. Sources: `ing/API-NOTES.md` (live-
verified) + git history. Three findings, one of them scope-changing:

1. **`distribute_group_balance` generalizes a DEAD branch → probably drop
   it (see §4).** ING's live CC-balance path emits each plastic's own
   `monthPurchasesAmount` with **no cross-row dependency**. The
   carrier/line-outstanding/priority machinery is a *fallback* that
   `f3c6086` left behind when it deleted the line-reconciliation — after
   verifying against the ING app that each card's balance simply *is* its
   `monthPurchasesAmount`. `API-NOTES.md` documents `monthPurchasesAmount`
   as *the* CC balance source, unconditionally. The fallback's tests are
   synthetic ("Defensive: if ING ever changes the shape"), pinning
   hypothetical, never-observed data. **The whole reason CC balances are
   "computed up front because a plastic depends on its line siblings" is
   this dead branch.** Live path has no sibling coupling.

2. **`remap_fields` is LIVE.** The extract attaches raw `/search` rows
   verbatim into `movements_by_uuid` (workflow.yml:314, 373); the
   normalizer owns the v2→legacy translation. Keep it. Note two dead
   *sub*-paths inside it: `/search` never emits a CC `status` hash
   (`API-NOTES.md` §"settlement renumber": status stays `posted`), so the
   ING plan's `map_status` step is dead under live data — always falls
   back to POSTED. `currency` is always `"EUR"`. Simplifies the ING plan.

3. **`collapse_prefix_dups` is LIVE but partial.** Per `API-NOTES.md`, it
   only catches the terse+enriched pair when both land in *one* `/search`
   response; the cross-fetch settlement-renumber case is resolved
   downstream (simplefreen HistoryStore supersession). Still needed — keep
   it, but don't expand its remit to cross-fetch.

Replay-only (not Tier B, but dead-code candidates once old dumps age out):
`unwrap_raw`'s legacy bare-Array branch and `translate_movement`'s
already-`uuid` passthrough exist only for `--from-raw` of pre-migration
payloads/fixtures.

**Finding #1 CONFIRMED against real data (2026-07-06).** Two production
ING extract dumps in `simplefreen/dev/freentonic-runs/audit-ING-*/raw.json`
— **every** type-3 (Tarjeta Crédito) product carries a numeric
`monthPurchasesAmount` (0.0, 360.44, 1067.82; never absent, nil, or a
string), across both runs. Branch 1 always fires; the fallback branch is
dead on real data. No live sync needed — the gate is passed.

---

## 1. `group_by` — EASY, crisp

Generalizes Fintonic's `by_product = txs.group_by { "#{bankId}_#{productId}_#{type}" }`.

**Return a list of groups, not a Hash.** A Hash forces `for_each` to walk
`[key, rows]` pairs (`Array({...})` → pairs) which the current
`collection_for` doesn't model. A list `[{ "key" => k, "rows" => [...] }]`
in first-appearance order iterates naturally and gives the plan
`sample = group.rows.first` — exactly the Fintonic idiom.

```ruby
define "group_by" do |f|
  f.param :rows,      :array,  required: true
  f.param :by,        :array,  required: true  # dotted paths, e.g. %w[bankId productId type]
  f.param :separator, :string                  # given → string key; absent → array tuple key
  # returns [{ "key" => <string|array>, "rows" => [row, ...] }, ...]
end
```

Semantics: read each `by` path from the row (non-Hash rows → nil
component); when `separator` given, `join` components (nil → "") to a
string key, else the key is the component array. Groups ordered by first
appearance; rows within a group keep input order.

Edge cases → tests (from `fintonic test_groups_by_product`, `..._deterministic`):
- three rows, two share a composite key → 2 groups, sizes [2, 1]
- nil component in `by` path → grouped under a stable nil-bearing key, not crash
- non-Hash row → its components are nil (grouped, not dropped — dropping is `for_each`'s job via `skip_when`)
- empty `rows` → `[]`

Open question (minor): tuple vs joined key. Fintonic wants a joined string
(`bankId_productId_type`); recommend `separator` optional and default to
the tuple. No provider needs the key value downstream, so this is low-stakes.

---

## 2. `tree_paths` — EASY, crisp

Generalizes Fintonic's `build_category_map`: `{id => {name/shortname, ancestors}}`
→ `{id => "Grandparent/Parent/Name"}`.

```ruby
define "tree_paths" do |f|
  f.param :tree,          :hash, required: true
  f.param :name_keys,     :array,  default: %w[name shortname]  # first present wins, else id
  f.param :ancestors_key, :string, default: "ancestors"
  f.param :root,          :string, default: "root"             # ancestor sentinel to drop
  f.param :separator,     :string, default: "/"
  # returns { id => "path/joined/by/separator" }
end
```

Semantics per node: `name = first present of name_keys, else id`;
`ancestors.reject(root).filter_map { |a| tree.dig(a, name_key) }`, append
own name, join. `filter_map` silently drops ancestor ids absent from the
tree (matches current behavior).

Edge cases → tests (from `fintonic test_category_resolved_from_tree`):
- node with ancestors `[root, A]` where A resolves → `"A/Name"`
- node with no `ancestors` key → just its own name
- ancestor id not in tree → dropped from path
- `name` missing but `shortname` present → uses shortname
- both missing → uses the id
- non-Hash `tree` → `{}` (guard as the current code does)

---

## 3. `collapse_prefix_dups` — MEDIUM, one real design choice

Generalizes ING's `collapse_pre_clearing_dups` + `collapse_one_group`:
group rows by a key, drop the shorter row(s) when **every** non-longest
row's whitespace-normalized text is a *strict* prefix of the longest's;
otherwise keep the whole group. Identical-text groups are kept (real
twins).

```ruby
define "collapse_prefix_dups" do |f|
  f.param :rows,     :array, required: true
  f.param :group_by, :array, required: true  # paths: %w[account_id date amount]
  f.param :text,     :string, required: true # path: "description"
  # returns the surviving subset of rows, input order preserved
end
```

Algorithm (port `collapse_one_group` verbatim):
1. group by the `group_by` paths
2. group size ≤ 1 → keep
3. all normalized texts identical → keep all (real twins)
4. `longest` = max by normalized length; if **all** others are strict
   prefixes (`longest.start_with?(other) && other.length < longest.length`)
   → keep only `longest`, else keep all

Edge cases → tests (direct ports, ING lines 536–656):
- terse vs enriched, prefix → collapse to enriched (`..._terse_vs_enriched`)
- whitespace-only difference, prefix after normalize → collapse (`..._whitespace_only`)
- identical descriptions → both kept (`test_real_twin...`)
- diverge mid-string → both kept (`test_distinct_postings...`)
- store-disambiguated twins → both kept (`test_real_twins_with_store...`)
- 3-way group, terse+enriched+unrelated → keep all 3 (`test_three_way_group...`)
- same (date, amount, text) on two accounts → not collapsed (group key includes account) (`test_collapse_does_not_cross_accounts`)

**Design choice — entities vs hashes. RESOLVED → A (via a shared dig).**
ING collapses *after* `build_transaction`, reading `t.account_id` /
`t.date` / `t.amount` / `t.description` off **canonical Transaction
entities** (`account_id` is a post-build digest, so you can't collapse
before building). So `collapse_prefix_dups` must read its `group_by` /
`text` paths off *entities*, not plain Hashes.

Check result: the entity member-reader is **not** reusable today. The
"walk a canonical entity's declared members" logic exists as two private,
byte-identical copies — `Interpreter#dig_path` (`interpreter.rb:371`) and
`Scope#step_into` (`scope.rb:95`) — and **neither is reachable from an Fn
impl**. The accessor the Fn layer *can* reach, `Providers::Helpers#dig_path`
(`helpers.rb:304`, wrapped as `HELPERS`), is Hash-only: it returns `nil`
on a `Data` entity, which would silently collapse every group into one
bucket.

Fix (do this first, it's a prerequisite for #3 and #1-general): **extract
the Data-aware dig into one shared module** (e.g. `Freentonic::PathDig`)
and route Interpreter, Scope, and the Fn layer through it. Net effect:
`group_by`/`collapse` get a principled members-whitelisted reader, the
interpreter/scope duplication collapses to one copy, and the "closed
member set, never arbitrary `send`" security property is preserved.
Rejected alternative: `.to_h`-then-Hash-dig — entities all define `to_h`,
but it wire-serializes money→String and date→ISO, so you'd group on lossy
projections and still have to carry the originals separately.

---

## 4. `distribute_group_balance` — LIKELY CUT (generalizes a dead branch)

**Revised after the real-data audit — this function should probably not be
built.** See Real-data findings §1. `compute_cc_balances` has three
branches; only the first is live:

1. **LIVE** — any plastic on the line has a numeric `monthPurchasesAmount`:
   each plastic emits `[-(round(mp*100)), "ing_live:card_purchases"]`. This
   is a **pure per-plastic map — no grouping, no carrier, no line total,
   no cross-row dependency.**
2. **DEAD (defensive)** — no plastic has `monthPurchasesAmount`: whole line
   outstanding (`creditLimit − availableBalance`) on a priority-picked
   carrier, rest 0. This is the residual `f3c6086` left when it deleted the
   line-reconciliation; never observed on real data; tests are synthetic.
3. NULL — no data → `[nil, nil]`.

**Everything hard about the original 10-param scope — the grouping, the
carrier priority ladder, the limit−available total, the two source labels
— lives only in the dead branch.** The live path needs none of it.

**Recommendation: don't build `distribute_group_balance`.** Express the
live CC-balance path in the ING plan with existing verbs:

```yaml
# inside the plan's per-CC-plastic loop
- apply: cents
  args: { amount: "{product.monthPurchasesAmount}" }
  as: mp_cents
- apply: negate            # tiny new leaf (see below) — or `cents` gains negate:
  args: { value: "{mp_cents}" }
  as: balance_cents
- apply: cents_to_amount
  args: { cents: "{balance_cents}" }
  as: balance_amount
```

The only new primitive implied is a **`negate` leaf** (plans can't do
arithmetic — `when_context` is comparison-only), or a `negate:` boolean on
`cents`. Cheaper and more honest than a reconciliation function no live
payload exercises.

**Handling the dead branch:** drop it. If ING ever *does* omit
`monthPurchasesAmount`, branch 3 (nil balance) already surfaces it in
`errors[]` downstream — same as `test_credit_card_without_limit_or_available`.
Losing the carrier fallback loses nothing real; it only stops synthesising
a balance from a figure (`limit − available`) that `f3c6086` proved wrong.

**Gate: PASSED.** Confirmed against two production raw dumps — every
type-3 CC plastic carries a numeric `monthPurchasesAmount` (Real-data
findings §1). The branch guarding against its absence can be deleted.

---

## 5. `remap_fields` — HARD, least crisp; needs a shape decision first

Generalizes ING's `translate_movement` → `coerce_v2_search_to_legacy_shape`:
rows matching a marker (`no "uuid"` AND has `transactionId`/`transactionDate`)
are reshaped from the /v2/search envelope to the legacy movement shape;
non-matching rows pass through untouched.

The catch: the reshape is **not** pure field renames. Its target fields
include computed values:
- `uuid` = `"v2-seq:#{productId}:#{seq}"`, **nil (→ row later dropped)** if
  either component is empty
- `amount` = strict `Float(string)` (garbage → drop)
- `effectiveDate` = `YYYY-MM-DD` → `DD/MM/YYYY`
- constants (`currency: "EUR"`, `_v2_source: true`), plain renames
  (`store ← concept`, `tranCode ← transactionCode`), and passthroughs

So `remap_fields` can't be a flat `{out => path}` map. Two viable shapes:

- **(A, recommended) gate + compose.** `remap_fields` owns only the
  *marker gate* + *straight renames/constants*; the computed fields
  (stable-uuid join, strict-float, date-reformat) are separate `apply:`
  steps composed around it in the plan's `for_each`. This keeps each
  function single-purpose and reuses `join` + a new strict-number coercion
  + a date-reformat helper. Needs 2 small new leaf functions:
  - `to_number_strict` (String→Float, raise→nil) — the `coerce_amount` core
  - `reformat_date` or a `parse_date`+`strftime` pair for `YYYY-MM-DD`→`DD/MM/YYYY`
- (B) `remap_fields`' `map:` values may themselves be `apply:` invocations
  (nested function calls). More powerful, but it turns one function into a
  mini-interpreter and widens the audit surface — pushes against the
  "closed, flat verb set" principle.

Edge cases → tests (ING lines 679–787):
- card row translates: stable id from `transactionId` not `transactionLocalUUID`, date reformatted, string amount → Numeric, status posted (`test_v2_search_card_row_translates`)
- `concept` → `store` surfaces as description disambiguator (`..._asset_concept_becomes_store`)
- signed string amounts survive (`..._signed_string_amounts`)
- missing `transactionId` → uuid nil → row dropped (`..._missing_transaction_id_is_dropped`)
- garbage amount → dropped (`..._garbage_amount_is_dropped`)
- terse+enriched same sequence → same id, collapse keeps enriched (`..._same_sequence_collapse`)
- legacy + raw movements mixed in one product → gate passes legacy rows through untouched (`test_legacy_and_raw_movements_mix`)

**Recommend shape (A):** scope `remap_fields` narrowly (gate + renames +
constants), add `to_number_strict` and a date-reformat leaf, and let the
plan's `for_each` compose the stable-uuid `join`. Decide A-vs-B before
writing any code — it changes what `remap_fields` even is.

---

## Recommended build order

Matches the plan's provider order and lands value early:

Ask 9 (ING-only under the new plan):
0. `Freentonic::PathDig` extraction (prereq for `collapse_prefix_dups`).
1. `collapse_prefix_dups`.
2. `remap_fields` + `to_number_strict` + date-reformat leaf.
3. `negate` leaf (replaces the cut `distribute_group_balance`, §4).
4. → **migrate `ing/normalizer.rb` to a plan; delete it.** ING's declarative
   plan reuses the existing `extract: plan:` already in its workflow.

Deferred (NOT Ask 9 — only if/when Fintonic migrates, which is last/never):
- `group_by` + `tree_paths` → Fintonic. Specs retained above.

Unrelated: Unicaja needs no Tier B — migrate whenever its normalizer exists.

## Decisions to lock before coding

1. ~~`group_by`/`collapse` read fields off hash-or-entity via the existing
   member accessor — confirm that accessor is reusable outside `select:`.~~
   **RESOLVED:** not reusable today (private + duplicated in
   interpreter/scope; the Fn-reachable `Helpers#dig_path` is Hash-only).
   Prereq: extract a shared `Freentonic::PathDig` and route all three
   through it. `group_by`/`collapse` return **list-of-groups**.
2. ~~`distribute_group_balance` carrier priority spec.~~ **RESOLVED → CUT
   the function** (Real-data findings §1; §4). Replace with a `negate`
   leaf. Gate PASSED — two production raw dumps confirm every CC plastic
   carries a numeric `monthPurchasesAmount`; fallback branch is dead.
3. `remap_fields` = **shape A** (narrow gate+rename, compose computed
   fields as sibling `apply:` steps) vs B (nested applies).
4. Leaf functions implied by the above: `negate` (for the cut #4),
   `to_number_strict` + date-reformat (for `remap_fields` shape A).
   Confirm they're worth registering vs folding into `cents`/`parse_date`.
```
