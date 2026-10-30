# `click_while_present`

Clicks a selector over and over while it is on the page — the shape of
"Load more" pagination, where each click fetches the next page and the
button disappears once the history is exhausted. Pair it with
[`capture_response_json`](workflow-action-capture-response-json.md)
`all: true` to collect every page the clicks loaded.

Every option is validated when the workflow loads, so a typo fails before
login and 2FA rather than in the middle of a run.

## Syntax

```yaml
- action: click_while_present
  selector: "button[data-testid='load-more']"
  max_clicks: 100
  settle_seconds: 2
  wait_for_response:
    url_includes: ["op=getTimelinePage"]
```

## Options

| Option           | Type      | Required | Default | Description |
| ---------------- | --------- | -------- | ------- | ----------- |
| `selector`       | `string`  | **yes**  | —       | CSS selector of the element to click. Found via `deepQuery` (traverses shadow DOM and iframes). |
| `max_clicks`     | `integer` | **yes**  | —       | Upper bound on clicks (1–1000). Required so a run can never click without end. |
| `settle_seconds` | `integer` | no       | `2`     | Seconds (1–60) to drain CDP events after each click, letting the page render before the next one. |
| `on_max_clicks`  | `string`  | no       | `fail`  | What happens when `max_clicks` is reached with the element still present: `fail` (the step raises — what was loaded is incomplete) or `warn` (prints a warning and carries on). |
| `wait_for_response` | `hash` | no      | —       | Require each click to fetch something — see below. |
| `stop_when_older_than_lookback` | `hash` | no | — | Stop paging once the loaded data reaches back past the run's lookback window — see below. |

### `wait_for_response`

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `url_includes` | `string[]` | **yes** | — | A click counts as done once a **new** response whose URL contains any of these arrives. |
| `timeout_seconds` | `integer` | no | `20` | Seconds (1–120) to wait for it. When none arrives the step fails. |

Without it, a click the page ignores (for example one landing before the
app has hydrated) looks the same as a click that loaded a page — paging
carries on blind, or stops early and looks complete. With it, that failure
is loud.

### `stop_when_older_than_lookback`

For date-ordered pagination (newest first), this makes a sync honor its
lookback the way a date-parameterised API call would: a 3-day sync stops
after the first page that reaches back 3 days instead of loading the whole
history.

| Key | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `url_includes` | `string[]` | **yes** | — | Responses to inspect (substring match) — typically the first page's request and the "load more" request. |
| `items_paths` | `string[]` | **yes** | — | Dotted paths to the list of items inside each response body. Numeric segments index arrays; a `*` segment fans out over every element (`data.modules.*.items`). Every path is tried on every response. |
| `timestamp_field` | `string` | no | `timestamp` | The item field holding the item's timestamp. |
| `timestamp_unit` | `string` | no | `ms` | `ms` (epoch milliseconds) or `s` (epoch seconds). |
| `items_where` | `hash` | no | — | Only items whose fields equal these literal values count, e.g. `{ type: TRANSACTION }` to ignore day headers. |
| `margin_hours` | `integer` | no | `0` | Page this many hours (0–168) further back than the window start — for a feed dated in a different time zone than the run. |

The window start is `ExtractPlan.window_start_ms` — the same `from_ms` an
`extract: plan:` filters on — so the browser stops paging at exactly the
boundary the plan keeps. Before each click, every new in-scope response is
read once (a body Chrome hasn't finished yet is read again later) and the
oldest qualifying timestamp is tracked; once it is older than the window
start minus `margin_hours`, the loop stops (logged as
`(lookback window covered)`).

What counts:

- **Scope.** Of the matching responses that arrived before the step, only
  the newest — the page on screen — is considered; older ones may belong to
  another view and must not end paging before it starts. Everything that
  arrives during the step counts.
- **Implausible timestamps are ignored.** A non-numeric value, `0`, or
  anything before 1973 once converted to milliseconds (usually seconds
  declared as `ms`) never ends paging.

Every run started by the CLI or the invoke server has a lookback (the
`--lookback-days` / request value, else the workflow's
`default_lookback_days`, else 14), so the stop always applies there. A
caller that builds a runner with no lookback in its runtime context gets no
stop: paging runs until the element disappears or `max_clicks`.

## Behaviour

- Each iteration looks the selector up. When it is **absent**, it's looked
  for twice more, a second apart (a re-render can unmount a button
  between pages); still absent ends the loop — the normal "no more pages"
  exit.
- A match that is `disabled` / `aria-disabled="true"` (a button mid-request)
  is waited on without counting as a click, for at most 30 seconds per
  click; past that the step fails.
- Otherwise it clicks, counts the click, waits for `wait_for_response` when
  set, and drains events for `settle_seconds`.
- Stops after `max_clicks` clicks. If the element is still present then and
  the lookback stop didn't fire, the step fails (`on_max_clicks: fail`) or
  prints `⚠ … still present after N clicks` (`on_max_clicks: warn`).
- Logs `[yml] click_while_present: <selector> (max N[, until DATE]) → K click(s)`.

## Example

```yaml
phases:
  capture_credentials:
    # Load pages until the lookback window is covered, one page per click …
    - action: click_while_present
      selector: "button[data-testid='feed-load-more-timeline-items']"
      max_clicks: 100
      wait_for_response:
        url_includes: ["op=getTimelinePage"]
      stop_when_older_than_lookback:
        url_includes: ["op=getFirstPage", "op=getTimelinePage"]
        items_paths: ["data.timeline.modules.*.timelineItems", "data.timeline.timelineItems"]
        items_where: { type: TRANSACTION }
        margin_hours: 24
    # … then capture every page's response.
    - action: capture_response_json
      url_includes: "op=getTimelinePage"
      field: data
      as: timeline_pages
      all: true
      required: false
```

## See also

- [`click_if_present`](workflow-action-click.md) — a single optional click
- [`capture_response_json`](workflow-action-capture-response-json.md) — `all: true` for multi-page captures
- [Workflow Actions Reference](workflow-actions.md)
