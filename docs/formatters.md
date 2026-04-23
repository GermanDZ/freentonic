# Freentonic Formatter Layer

## Purpose

Formatters turn a `CanonicalPayload` into an output shape. Exporters ship
those bytes somewhere. The two are decoupled: **exporters handle
"where it goes," formatters handle "what shape it's in."**

The split lets the same wire shape travel through multiple transports with
one implementation. Writing a SimpleFIN dump to disk during development and
POSTing the same SimpleFIN shape to a real receiver in production is the
same formatter behind two exporters.

## Contract

### Base class

```ruby
# lib/freentonic/formatters/base.rb
module Freentonic
  module Formatters
    class Base
      def initialize(options = {})
        @options = options
      end

      # Convert a CanonicalPayload into the output shape.
      # Must return one of:
      #   - Hash  / Array — caller will JSON-encode
      #   - String        — caller will write bytes as-is
      def call(canonical_payload)
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      # Declared content-type for HTTP exporters. Defaults to application/json
      # because most formatters return structured (Hash/Array) output.
      def content_type
        "application/json"
      end
    end

    @registry = {}

    class << self
      def register(name, klass)
        @registry[name.to_sym] = klass
      end

      def registered
        @registry.keys.sort
      end

      def build(name, options = {})
        klass = @registry[name.to_sym]
        raise UserError,
              "unknown format #{name.inspect} (available: #{registered.join(', ')})" unless klass
        klass.new(options)
      end
    end
  end
end
```

### Return-type rules

| Return type          | How exporters handle it                    |
| -------------------- | ------------------------------------------ |
| `Hash` or `Array`    | `JSON.generate(value)` then write/POST     |
| `String`             | Write/POST as-is; `content_type` is authoritative |

Formatters that produce JSON-shaped output (canonical, SimpleFIN, …) return
structured values — the exporter handles serialization so concerns like
pretty-printing or streaming can live in one place.

Formatters that produce non-JSON formats (OFX XML, CSV) return `String` and
declare the appropriate `content_type`.

### `content_type`

Declared by the formatter. Consumed by the `http` exporter to set the
outgoing `Content-Type` request header. Ignored by file-based exporters
(they don't care). Defaults to `application/json` in `Base`; override only
when producing non-JSON output.

Examples:

| Formatter               | `content_type`         |
| ----------------------- | ---------------------- |
| `Canonical`             | `application/json`     |
| `CsvTransactions`       | `text/csv`             |
| `JsonlTransactions`     | `application/x-ndjson` |
| Future `SimpleFIN`      | `application/json`     |
| Future `Ofx`            | `application/x-ofx`    |

## Built-in formatters (first cut)

Three ship in the initial migration. SimpleFIN and OFX are deferred to
dedicated follow-up PRs (each is substantive format-specific work).

### `Canonical`

Identity formatter. Calls `canonical_payload.to_h` and returns the hash.
This is the default for the `http` and `json` exporters.

```ruby
module Freentonic
  module Formatters
    class Canonical < Base
      def call(payload)
        payload.to_h
      end
    end
    register(:canonical, Canonical)
  end
end
```

Output matches the JSON shape documented in
[canonical-data-model.md](canonical-data-model.md) exactly.

### `CsvTransactions`

Flattens the `transactions` slot to rows, hoisting fields from the owning
account as `account_*` columns (`account_id`, `account_name`,
`account_currency`, etc.). Becomes the default formatter for the `csv`
exporter.

Row shape (columns are the union of keys across all rows, sorted
deterministically):

- All `Transaction` fields prefixed verbatim (`id`, `amount`, `description`, …).
- Account context columns: `account_id`, `account_name`, `account_currency`,
  `account_institution`. (Not every `Account` field — only ones commonly
  useful in a flat row view. Authors who need more can use a custom
  formatter later.)
- Nested structures (`merchant`, `metadata`) are JSON-stringified into a
  single cell, matching the previous `csv` exporter's behavior for nested
  hashes/arrays.
- Money fields written as their wire string form (`"-45.20"`).

Replaces today's `--export-select "accounts.movements"` logic: slot names
are now fixed, so the formatter knows to look at `transactions` without
being told.

### `JsonlTransactions`

Same flattening logic as `CsvTransactions`, but emits one JSON object per
line (with newline terminators). Becomes the default formatter for the
`jsonl` exporter.

Wire content-type: `application/x-ndjson`.

## Exporter integration

### `Exporters::Base` changes

`Base` gains a small helper:

```ruby
def resolve_formatter
  name = @options[:format] || default_format
  Formatters.build(name, @options.fetch(:format_options, {}))
end

# Subclasses override to pick their default formatter name.
def default_format
  :canonical
end
```

### Per-exporter defaults

| Exporter | Default `format` | Notes                                                |
| -------- | ---------------- | ---------------------------------------------------- |
| `http`   | `canonical`      | `Content-Type` comes from the formatter.             |
| `json`   | `canonical`      | Writes the full envelope as pretty-ish JSON.         |
| `jsonl`  | `jsonl_transactions` | Drops `--export-select`; slot is fixed to `transactions`. |
| `csv`    | `csv_transactions`   | Drops `--export-select`; slot is fixed to `transactions`. |

Any exporter/format combination is legal as long as the formatter returns a
type the exporter can handle. E.g. `--export json --export-format csv_transactions`
would write a CSV string to a file with a `.json` extension — silly but
not an error; the user chose the filename.

## CLI surface

```
--export <name>              # pick exporter (http, json, jsonl, csv)
--export-format <format>     # pick formatter; attaches to the most recent --export
--export-url <url>           # http-only
--export-token <token>       # http-only
--export-method POST|PUT     # http-only
--export-content-type <mime> # http-only; overrides the formatter's declared content_type
--export-path <path>         # file-based
--export-header K:V          # http-only; repeatable
```

`--export-format` follows the same "attaches to the most recently declared
`--export`" grouping pattern as the existing `--export-url` / `--export-token`
flags. Multiple `--export` groups may each carry their own `--export-format`.

`--export-content-type` stays as an existing HTTP-specific override; when
present it wins over `formatter.content_type`.

## Extension surface

This first cut is **closed** — the `--export-format` flag only resolves to
names registered in the built-in registry. Plugin-loadable formatters (per-workflow
custom formatters declared in YAML, analogous to `normalize:`) are an
explicit future extension and are NOT supported yet. Reasons:

- No concrete customer need yet (see migration plan's Q5 resolution).
- The plugin contract is better designed after SimpleFIN and OFX land and
  we know what a real formatter looks like.

When plugin-loading is added, the entry point will be `Formatters.register`
plus a `formatters:` section in the workflow YAML — same shape as
normalizers. Built-in names always win over workflow-declared names on
collision (i.e., a workflow cannot shadow `canonical`).

## Future built-in formatters

Tracked as follow-up work:

- `SimpleFIN` — maps canonical accounts + transactions to the SimpleFIN
  JSON shape. Content-type `application/json`.
- `Ofx` — emits OFX 2.x XML. Content-type `application/x-ofx`. Strict
  formatting; test fixtures required.
- Possibly `CsvAccounts` / `JsonlAll` if users ask for alternative flattenings.

Each is a new class under `lib/freentonic/formatters/`, registered under a
new symbol, documented in this file. No architectural changes needed.

## Testing

Formatters are unit-testable against hand-built `CanonicalPayload`
fixtures — no real workflow or network required. Every built-in formatter
MUST ship with:

- A golden-output test against a canonical fixture covering multiple
  accounts / multiple currencies / pending+posted transactions.
- A content-type assertion.
- A round-trip test for formatters that produce a parseable format
  (canonical → JSON → parse → reconstruct entities, with structural
  equality check).
