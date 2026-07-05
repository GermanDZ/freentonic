# Provider asks: capabilities to make ING fully declarative

*Incoming requirements from the
[freentonic-providers](https://github.com/GermanDZ/freentonic-providers)
authors.*

ING is the last provider carrying an `extractor.rb`. This doc lists
exactly which framework capabilities are missing, why the framework is
the right home for each behavior, and what the end state looks like.
Every ask extends a primitive that already exists in this repo — none
of this is new architecture.

## Where the provider program stands

*Status audited against main @ `f1137f2` (PR #32 merged).*

| Provider | Extract | Blocked on |
| --- | --- | --- |
| Revolut | `extract: plan:` (on providers main) | — |
| Fintonic | `extract: plan:` (branch) | Phase-2 verbs reaching main (see ⚠ below) |
| Unicaja | `extract: plan:` (branch) | same |
| **ING** | `extractor.rb` (~390 lines) | **the asks below** |

> ⚠ **Ask 0 — forward the stranded Phase-2 verbs to main.** PR #33
> (`let/coalesce`, `concat`, `dedup_by`, `when:` gate, `today` /
> `lookback_days` seed bindings) merged into the
> `p3-declarative-extract-plan` branch moments *after* PR #32 had
> already merged that branch into main — so the verbs exist only on the
> p3 branch (merge commit `4f67d07`), not on main. Until a follow-up PR
> forwards them, the Fintonic/Unicaja plans fail `--lint` against main
> with unknown-verb errors. This is a ten-minute PR and gates
> everything else.

The insight that unlocked this: **everything imperative left in ING is
session lifecycle, not extraction.** The extractor used to be four jobs
in one file — preflight diagnostics, SCA elevation + Bearer rotation,
fetch orchestration, and shape translation. Providers PR
[#28](https://github.com/GermanDZ/freentonic-providers/pull/28) already
moved shape translation to the normalizer (the extractor now attaches
raw `/search` rows verbatim). What remains splits cleanly into
"session management" (asks 1–4) and "orchestration" (ask 5).

## Ask 1 — request headers on endpoint declarations

**Gap.** `define_get`/`define_post` accept `base:`, `params:`,
`pagination:`, `response_extract_batch:` — but no request headers. The
two SCA handshake calls are the only reason `client.raw_request` still
exists in any provider:

```ruby
# providers ing/extractor.rb — the whole raw_request surface:
client.raw_request(method: :get,  path: "/genoma_api/rest/sca/documentation",
                   headers: { "x-ing-reset-validations" => "1" },          # static
                   base: "https://ing.ingdirect.es")
client.raw_request(method: :put,  path: "/genoma_api/rest/sca/documentation",
                   headers: { "x-ing-securityprocessid" => process_id },   # per-call
                   body: { "processId" => process_id },
                   base: "https://ing.ingdirect.es")
```

**Ask.** Two additions to the endpoint YAML:

```yaml
- name: sca_documentation_challenge
  method: GET
  path: "/genoma_api/rest/sca/documentation"
  base: "https://ing.ingdirect.es"          # already supported
  headers:                                   # NEW: static headers
    x-ing-reset-validations: "1"
- name: sca_documentation_commit
  method: PUT                                # NEW: PUT verb if not present
  path: "/genoma_api/rest/sca/documentation"
  base: "https://ing.ingdirect.es"
  headers:
    x-ing-securityprocessid: "{process_id}"  # NEW: templated from kwargs
  json:
    processId: "{process_id}"
```

With this, `raw_request` disappears from providers entirely and the SCA
endpoints become `--lint`-checkable like everything else.

## Ask 2 — `await_operator_approval` step

**Gap.** The browser workflow grammar already has
`await_external_approval` (message / wait condition / timeout) — Revolut
uses it for push-2FA at login. ING needs the same *pause for a human*
mid-API-flow: trigger the SCA push, wait for the operator to approve on
their phone, continue.

**Ask.** An API-side step that wraps the existing prompt-store
primitive — the interface already matches exactly:

```ruby
# lib/freentonic/remote_prompt_store.rb — exists today:
def prompt(kind:, message:, mask: false, timeout_seconds:, until_satisfied: nil)
```

```yaml
- await_operator_approval:
    message: "ING is requesting SCA to release older history. Approve on your phone. (challenge: {challenge.acceptanceMethods.0.code})"
    timeout: 180
```

Semantics: prompt-store absent or timeout → the step *fails* (feeding
the `on_failure:` policy of ask 4), never hangs headless runs.

## Ask 3 — `rebind_credential:` (declared credential data-flow)

**Gap.** After SCA, ING mints a high-LoA Bearer and the extractor
installs it imperatively:

```ruby
client.update_auth_headers!({ "Authorization" => "Bearer #{new_bearer}" },
                            host: "api.ing.ingdirect.es")
```

`update_auth_headers!` is an arbitrary mutation — but what ING actually
does is fully constrained: *one dotted path from one declared endpoint's
response becomes one named header on one named host.* That's
`derived_credentials` (which exists) running in reverse.

**Ask.** Declare it as data-flow:

```yaml
- fetch: refresh_access_token          # already a declared endpoint
  as: refreshed
- rebind_credential:
    header: Authorization
    host: api.ing.ingdirect.es
    value: "Bearer {refreshed.accessTokens.0.accessToken}"
```

Lint can verify the source binding exists, the host appears in the
`auth_headers` host-scoped blocks, and nothing else is touchable. This
is *more* auditable than the Ruby, not less: today ING's rotation powers
are discoverable only by reading the extractor; here they're four lines
of YAML. If the templated value resolves empty/nil, the step fails
(→ `on_failure:` policy) rather than installing a broken header.

## Ask 4 — an `elevate:` phase (composition of 1–3)

**Gap.** Nowhere declarative to *put* the handshake. It isn't extraction
(it mutates session state) and it isn't login (it's conditional on the
requested lookback). It's a third lifecycle moment: session elevation.

**Ask.** A workflow section that runs between connect and extract:

```yaml
elevate:
  when: { lookback_days_gt: 90 }    # Phase-2 `when:` + `lookback_days` seed binding
  on_failure: degrade               # warn + continue with the captured Bearer
  steps:
    - fetch: sca_documentation_challenge
      as: challenge
    - await_operator_approval:
        message: "ING is requesting SCA… approve on your phone."
        timeout: 180
    - fetch: sca_documentation_commit
      args: { process_id: "{challenge.acceptanceMethods.0.securityProcessId}" }
    - fetch: refresh_access_token
      as: refreshed
    - rebind_credential:
        header: Authorization
        host: api.ing.ingdirect.es
        value: "Bearer {refreshed.accessTokens.0.accessToken}"
```

The `on_failure: degrade` policy is load-bearing — it encodes ING's
current behavior matrix verbatim (see the routing matrix in the
extractor's header comment): SCA timeout, missing processId, or empty
refreshed token all warn and continue with the low-LoA Bearer (history
truncates at ~90d). `abort` should also exist for providers where
elevation is mandatory. The steps interpreter is the *same* one as
`extract: plan:` — same scope, same templates, same linter — plus the
two new step kinds.

## Ask 5 — three small plan verbs for the remaining extract

Once 1–4 land, ING's extract is pure orchestration except for three
idioms the current grammar can't express:

1. **`index_by:` / find-by-field** — the V1ID→UUID map walks
   `products[].identifiers[]` picking `type == "LOCAL_UUID"` /
   `type == "UUID"` values into a lookup hash (`build_uuid_map`).
   Pure shape work: index a list into a map by extracted keys.
2. **Skip-with-warning routing** — per-product: investment → skip
   loudly (a single investment UUID 401-poisons a multi-UUID batch),
   loan → balance-only, missing v2 UUID → warn + skip. Needs
   `skip_when:` + a `warn:`/`note:` message verb so operators keep
   today's breadcrumbs. The kind lookup itself is data providers
   already ship (`kind_by_product_type` in `ing/config.yml`).
3. **Fatal fetch with a custom message** — `/position-keeping` failure
   must abort with an operator-actionable message (a 0-product payload
   would read downstream as "all accounts deleted"). Something like
   `on_error: { abort: "ING extract: /position-keeping failed… re-run after a fresh login." }`.
   The same verb covers the two preflight checks (Bearer captured →
   abort; XSRF cookie present → warn only).

## What we are NOT asking for

- **No `ruby_step:` escape hatch.** Considered and rejected: it would
  reintroduce the audited-Ruby surface inside YAML and every borderline
  provider would reach for it.
- **No computing verbs.** The guardrail we've been applying: plan verbs
  may *filter, dig, index, and guard*; the moment a verb computes
  (arithmetic, string surgery beyond `{templates}`), that work belongs
  in the normalizer. ING's remaining computation (amount coercion, date
  reformat, v2-seq id synthesis) already moved there in providers #28.

## Sequencing

1. ~~PR #32 (base `extract: plan:` grammar)~~ — **done**, on main
   (`f1137f2`) with the grammar reference at
   [docs/extract-plan.md](extract-plan.md).
2. **Ask 0** — forward the stranded PR #33 verbs from
   `p3-declarative-extract-plan` to main (see ⚠ above); unblocks the
   Fintonic + Unicaja providers branch. *Verified missing from main:*
   `git grep dedup_by origin/main -- lib` returns nothing.
3. **Asks 1–4** (endpoint headers, `await_operator_approval`,
   `rebind_credential:`, `elevate:` phase) — one coherent
   "session-elevation" feature; ask 1 is independently useful and could
   ship first. *All verified absent from main @ `f1137f2`.*
4. **Ask 5** (index_by, skip-with-warn, on_error message) — small,
   after which `ing/extractor.rb` is deleted and every provider is
   zero-Ruby except normalizers.

End state: the only Ruby a provider PR can contain is a normalizer, and
everything a provider is *allowed to do* to a session is enumerable by
grepping its `workflow.yml`.
