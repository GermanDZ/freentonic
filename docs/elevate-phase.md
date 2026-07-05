# Session elevation (`elevate:` phase)

Some banks won't hand over full history to a freshly-restored session.
Reaching further back requires a *session-elevation* handshake — a PSD2
Strong Customer Authentication (SCA) challenge the operator approves on
their phone, after which the bank mints a higher-assurance Bearer token
the client must adopt for the rest of the run.

That work is neither login nor extraction. It runs *after* connect (it
needs the captured session) but *before* extract (it changes what extract
can see), and it **mutates the session** — something a declarative
`extract: plan:` is deliberately forbidden from doing. The `elevate:`
block is where it lives.

The pipeline is now:

```
Connect → Elevate → Extract → Normalize → Export
```

The Elevate stage is a **no-op** for any workflow without an `elevate:`
block, so existing providers are unaffected.

## The grammar

```yaml
elevate:
  when: { lookback_days: { gt: 90 } }   # optional block-level gate
  on_failure: degrade                   # degrade | abort (default: abort)
  steps:
    - fetch: sca_documentation_challenge
      as: challenge
    - await_operator_approval:
        message: "ING is requesting SCA. Approve on your phone. (challenge {challenge.acceptanceMethods.0.code})"
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

The step sequence reuses the **`extract: plan:` grammar** — `fetch`,
`select`, `for_each`, `let`, `concat`, `dedup_by`, each optionally
`when:`-gated — over the workflow's declared `api_client` endpoints, with
the same seed bindings (`from_date`, `from_ms`, `now_ms`, `today`,
`lookback_days`). See [docs/extract-plan.md](extract-plan.md) for those.
There is **no `output:`** — an elevate phase produces no value; its effect
is the session mutation it leaves on the client.

### `when:` — run elevation only when it's worth it

The block-level `when:` gate reuses the `when_context` operator set
(`gt`/`gte`/`lt`/`lte`, `eq`/`neq`, `present`/`absent`). When it fails,
elevation is skipped cleanly — not degraded, not aborted — and Extract
runs against the un-elevated session. The canonical gate is
`lookback_days` (skip the SCA dance on short runs that don't need extended
history).

### `on_failure:` — what a failed handshake does

| Policy | Behavior |
| --- | --- |
| `abort` (default) | The run fails with the error. Use when elevation is mandatory. |
| `degrade` | Warn and continue with the **un-elevated** session; Extract rebuilds a pristine client, so a half-applied elevation is discarded. Use when reduced history is acceptable (e.g. ING truncates to ~90 days). |

An approval timeout, a missing operator channel, an empty rebind value,
or any fetch error inside the phase all route through this policy.

## The two elevate-only step kinds

### `await_operator_approval: { message:, timeout: }`

Pauses the flow and surfaces a confirm prompt through the same
`RemotePromptStore` the invoke server watches — the operator sees a
"waiting on you" card in the admin UI, approves the challenge in their
bank app, and clicks to continue. `timeout` defaults to 180 seconds.

`message` may embed `{tokens}` (see *Templating* below) so the operator
sees the live challenge code. If there is **no operator channel**
(neither an invoke-server run directory nor an interactive session), the
step *fails* rather than hanging a headless run — `on_failure:` decides
what that means.

### `rebind_credential: { header:, host:, value: }`

Installs `value` as the `header` auth header on the client (optionally
scoped to a single `host:`), via `update_auth_headers!`. This is the one
sanctioned session mutation — the declarative form of the imperative
Bearer rotation an extractor used to perform in Ruby. Because the Elevate
stage and the Extract stage **share one client instance** (stashed in
`context[:api_client]`), the rebind is visible to the whole fetch loop
that follows.

If the resolved `value` is empty or any of its tokens resolve to nil, the
step fails rather than installing a truncated credential.

## Templating

The plan grammar uses a strict *whole-token* rule: a string is a template
only if it is exactly `"{name}"`. That is too strict for the human and
credential strings elevation needs — a challenge code inside a sentence,
or `"Bearer {token}"`. So `message:` and `value:` use a richer resolver:

- **Embedded tokens** — `{token}` anywhere inside surrounding text.
- **Array indices** — an integer path segment digs into an Array:
  `{refreshed.accessTokens.0.accessToken}`. (Array-index digging also now
  works in plan `select:`/`output:` paths.)

Everything else — `fetch` `args:`, `for_each`, etc. — keeps the plan's
whole-token rule unchanged.

## Static validation

Loading the workflow (and `--lint`) checks the whole block offline:

- every `fetch:` names a declared `api_client` endpoint,
- every `{token}` — whole or embedded — references a name bound by an
  earlier step or a seed binding,
- `await_operator_approval` has a non-empty `message:` and a positive
  integer `timeout:`,
- `rebind_credential` has a non-empty `header:` and `value:`,
- `on_failure:` is `degrade` or `abort`,
- each step declares exactly one verb.

So a typo'd endpoint, a dangling reference, or a malformed step fails
before a single request is made — not mid-handshake.

## What elevation may *not* do

The elevate interpreter adds exactly two capabilities to the plan grammar
(`await_operator_approval`, `rebind_credential`). It cannot call
`raw_request` or any client method outside the declared-endpoint
whitelist, and it has no `ruby:` escape hatch. Everything a workflow is
allowed to do to a session is enumerable by reading its `elevate:` block.
