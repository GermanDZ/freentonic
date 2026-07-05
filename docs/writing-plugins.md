# Writing plugins

Freentonic has three extension points. Each one is a registry-based
plugin: you subclass a small base class, register your class under a
short name, and freentonic looks you up by that name at load time.

| Extension point | Base class                         | Registry                         | Loaded by                              |
| --------------- | ---------------------------------- | -------------------------------- | -------------------------------------- |
| Exporter        | `Freentonic::Exporters::Base`      | `Freentonic::Exporters.register` | `--export NAME` CLI flag               |
| Secret backend  | `Freentonic::Secrets::Store`       | `Freentonic::Secrets.register`   | `--secrets NAME` CLI flag              |
| Normalizer      | `Freentonic::Normalizers::Base`    | —                                | `normalize:` stanza in a workflow YAML |

All three are loaded through the same `-r` mechanism at the CLI:

```sh
freentonic -r ./my_plugin.rb --workflow provider.yml --export my_exporter
```

The `-r` flag is pre-processed **before** OptionParser sees `--export`,
so your file has a chance to call `Freentonic::Exporters.register(...)`
in time. You can pass `-r` multiple times or chain it with `ruby -r`
tricks — whatever works for your setup.

There is no plugin discovery, no gemspec change, no framework fork
required. Drop a file on disk, pass `-r`, go.

## Prerequisites

- A freentonic checkout. This doc assumes you're working in a directory
  alongside your `freentonic` clone so that `ruby -I../freentonic/lib`
  resolves the library. A published gem works the same way — just drop
  the `-I` flag.
- Ruby ≥ 3.2. Same floor as the framework.

```sh
# Scaffold a workspace for a plugin
mkdir -p my_plugin/test
touch my_plugin/{my_exporter.rb,test/my_exporter_test.rb}
```

---

## Writing an exporter

Exporters receive the normalized payload from the Export stage and do
something with it — write a file, POST a webhook, push to a queue, call
an SDK.

### Contract

```ruby
module Freentonic
  module Exporters
    class Base
      def initialize(options = {}); @options = options; end
      def write(payload); raise NotImplementedError; end

      # Helper: yields an IO. path = nil | "-" means stdout.
      protected def open_output(path, &block); end
    end
  end
end
```

Your subclass needs to implement `#write(payload)`. The options hash is
whatever CLI flags the user attached to `--export your_name` via
`--export-*` flags. Freentonic ships four `--export-*` flag shapes:

| Flag                      | Winds up as       | Use for                    |
| ------------------------- | ----------------- | -------------------------- |
| `--export-path PATH`      | `options[:path]`  | file output                |
| `--export-url URL`        | `options[:url]`   | network destinations       |
| `--export-token TOKEN`    | `options[:token]` | auth                       |
| `--export-header KEY=VAL` | `options[:headers]` (Hash) | auth / metadata |

You can read arbitrary options if you pre-process `-r` yourself, but
the four above cover nearly every practical case.

### Example: a Slack-webhook exporter

```ruby
# my_plugin/slack_exporter.rb
require "net/http"
require "uri"
require "json"

module Freentonic
  module Exporters
    class Slack < Base
      def write(payload)
        url = @options[:url] or raise UserError, "slack exporter: --export-url is required"
        uri = URI(url)

        accounts = Array(payload["accounts"])
        total_movements = accounts.sum { |a| Array(a["movements"]).size }

        body = {
          text: ":chart_with_upwards_trend: Freentonic run complete — " \
                "#{accounts.size} accounts, #{total_movements} movements " \
                "(source: #{payload['source_tag']})"
        }

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        resp = http.request(req)

        unless (200..299).cover?(resp.code.to_i)
          raise ExportError, "slack exporter: POST failed with HTTP #{resp.code}"
        end
      end
    end

    register(:slack, Slack)
  end
end
```

Use it:

```sh
freentonic -r ./my_plugin/slack_exporter.rb \
  --workflow providers/my_bank/workflow.yml \
  --from-normalized /tmp/my_bank.json \
  --export slack --export-url https://hooks.slack.com/services/XXX/YYY/ZZZ
```

### Testing an exporter

Stub the network boundary so tests never actually POST. The pattern the
framework uses for its own HTTP exporter lives in
`test/exporters_test.rb` — copy from there:

```ruby
# my_plugin/test/slack_exporter_test.rb
require "minitest/autorun"
require "stringio"
require "freentonic"
require_relative "../slack_exporter"

class SlackExporterTest < Minitest::Test
  FakeResp = Struct.new(:code, :body) { def [](_); nil; end }

  def with_net_http_new(replacement)
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*_, **_| replacement }
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, original) if original
  end

  def test_posts_a_summary_line
    fake = Object.new
    fake.define_singleton_method(:use_ssl=) { |_| }
    captured_body = nil
    fake.define_singleton_method(:request) do |req|
      captured_body = JSON.parse(req.body)
      FakeResp.new("200", "ok")
    end

    with_net_http_new(fake) do
      Freentonic::Exporters::Slack.new(url: "https://hooks.slack.com/x/y/z").write(
        { "source_tag" => "ing_push",
          "accounts"   => [{ "movements" => [{}, {}] }] }
      )
    end

    assert_includes captured_body["text"], "1 accounts"
    assert_includes captured_body["text"], "2 movements"
  end
end
```

Run it:

```sh
ruby -I../freentonic/lib -Imy_plugin my_plugin/test/slack_exporter_test.rb
```

---

## Writing a secret backend

Secret backends own "where do credentials live?". Freentonic ships three
(ephemeral CLI, macOS Keychain, plain-file) but every real deployment
environment has its own preferred secret store.

### Contract

```ruby
module Freentonic
  module Secrets
    class Store
      def fetch(source_key:, secret_name:)
        # Returns the stored value as a String, or nil if not stored.
      end

      def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
        # Prompts the user for the value and optionally persists it.
        # MUST NOT return nil — raise Freentonic::UserError if the user
        # cannot supply a value (e.g. non-interactive backend, missing
        # entry in a read-only store).
      end
    end
  end
end
```

The contract is intentionally tiny. `fetch` returns what's stored,
`prompt_and_store` is called when `fetch` came back nil or empty. The
`SecretResolver` caches results per `(source_key, secret_name)` so
inside one run your backend is hit at most once per secret.

**Configuration options.** Both registries construct instances the same
way — `Secrets.build(name, options)` and `Exporters.build(name, options)`
take an options hash and pass it to your class. For a secret backend the
options are splatted to a keyword initializer, so a backend that needs
configuration just declares the keywords it wants:

```ruby
class Vault < Store
  def initialize(address:, namespace: "secret")
    @address = address
    @namespace = namespace
  end
  # ...
end

# Freentonic::Secrets.build(:vault, address: "https://vault.internal")
```

If your backend takes no options, `initialize` can be omitted entirely
(the default `Store#initialize` accepts none).

### Example: a 1Password CLI backend

```ruby
# my_plugin/onepassword_backend.rb
require "open3"

module Freentonic
  module Secrets
    class Onepassword < Store
      VAULT = "freentonic"

      def fetch(source_key:, secret_name:)
        stdout, _stderr, status = Open3.capture3(
          "op", "read", "op://#{VAULT}/#{source_key}/#{secret_name}"
        )
        status.success? ? stdout.strip : nil
      rescue Errno::ENOENT
        raise UserError,
              "1password backend: `op` CLI not in PATH — install the " \
              "1Password CLI or pass --secrets cli to prompt interactively"
      end

      def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
        raise UserError,
              "1password backend: secret #{secret_name} not found at " \
              "op://#{VAULT}/#{source_key}/#{secret_name}. Store it in " \
              "1Password and re-run. (prompt: #{prompt})"
      end
    end

    register(:onepassword, Onepassword)
  end
end
```

Use it:

```sh
freentonic -r ./my_plugin/onepassword_backend.rb \
  --secrets onepassword \
  --workflow providers/my_bank/workflow.yml \
  --export http --export-url https://receiver.example/ingest
```

### Testing a secret backend

Your `fetch` will shell out, so stub `Open3.capture3` or drive the
backend with a fake. The framework's own test for the macOS Keychain
backend is the simplest reference — `test/secrets_test.rb` shows the
`plain_file` and `cli` variants with no shelling at all.

```ruby
# my_plugin/test/onepassword_backend_test.rb
require "minitest/autorun"
require "freentonic"
require_relative "../onepassword_backend"

class OnepasswordBackendTest < Minitest::Test
  def with_capture3_stub(stdout:, success:)
    original = Open3.method(:capture3)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    Open3.define_singleton_method(:capture3) { |*_args| [stdout, "", status] }
    yield
  ensure
    Open3.define_singleton_method(:capture3, original) if original
  end

  def test_returns_stored_value
    backend = Freentonic::Secrets::Onepassword.new
    with_capture3_stub(stdout: "hunter2\n", success: true) do
      assert_equal "hunter2", backend.fetch(source_key: "ing", secret_name: "PIN")
    end
  end

  def test_returns_nil_when_op_missing_the_entry
    backend = Freentonic::Secrets::Onepassword.new
    with_capture3_stub(stdout: "", success: false) do
      assert_nil backend.fetch(source_key: "ing", secret_name: "PIN")
    end
  end
end
```

### Security reminders for secret backends

- **Never log the secret value** — only names. The stdout/stderr IOs
  you receive are user-facing and often captured in CI logs.
- **`prompt_and_store` must raise rather than return nil or empty** so
  freentonic fails loud rather than trying to POST with a blank token.
- **If your backend can't prompt** (e.g. CI, non-interactive), raise
  with an actionable message that tells the user exactly what key to
  add, where.
- Read [`SECURITY.md`](../SECURITY.md) end-to-end before you ship a
  backend used by anyone other than you.

---

## Writing a normalizer

Normalizers convert the Extract stage's raw provider payload into a
`Freentonic::Canonical::CanonicalPayload` — the universal internal
shape every exporter consumes. Most of the time,
normalizers live alongside their workflow YAML in the
[freentonic-providers](https://github.com/GermanDZ/freentonic-providers)
repo — the contract is the same either way.

The canonical model itself (entities, required fields, ID strategy,
wire-format rules) is specified in
[canonical-data-model.md](canonical-data-model.md). Read that first.

### Contract

```ruby
module Freentonic
  module Normalizers
    class Base
      def call(raw, context: {})
        raise NotImplementedError
      end
    end
  end
end
```

`raw` is whatever the extractor returned (Hash, Array, anything
JSON-serializable). `context` is the shared pipeline context — you
rarely need it, but it's there if you want the source key, credentials,
or the resolved `lookback_days`.

Return a `Freentonic::Canonical::CanonicalPayload`. The csv/jsonl
exporters reject any other payload type with a clear error pointing at
this doc; the http/json exporters accept plain Hashes too (they're
serialized as-is), but you should always emit a canonical payload so
consumers see the `schema_version` / `summary` / deterministic-IDs
benefits.

### Registration

Unlike exporters and secret backends, normalizers are loaded by path
from the workflow YAML, not by a name in a registry:

```yaml
# providers/my_bank/workflow.yml
normalize:
  ruby: ./normalizer.rb
  class: Freentonic::Providers::MyBank::Normalizer
```

The `ruby:` path is resolved relative to the YAML file's directory. The
`class:` name is resolved via a strict nested `const_get(name, false)`
walk, so there is no opportunity for string-interpolated constant
lookup — the class name must exactly match what you declared.

Skip the `normalize:` stanza entirely and freentonic falls back to
`Freentonic::Normalizers::Passthrough`, which returns `raw` unchanged.

### Example: a minimal canonical normalizer

```ruby
# my_plugin/normalizer.rb
module MyBank
  class Normalizer
    INSTITUTION = "my_bank"

    def call(raw, context: {})
      accounts = Array(raw["accounts"]).map { |a| build_account(a) }
      transactions = Array(raw["movements"]).map { |m| build_transaction(m) }

      Freentonic::Canonical::CanonicalPayload.new(
        accounts: accounts,
        transactions: transactions,
        meta: { "scraper_version" => "my_bank/1.0" }
      )
    end

    private

    def build_account(raw_account)
      Freentonic::Canonical::Account.new(
        id: Freentonic::Canonical.account_id(
          institution: INSTITUTION,
          iban: raw_account["iban"],
          source_id: raw_account["ref"]
        ),
        source_id: raw_account["ref"],
        institution: INSTITUTION,
        name: raw_account["alias"],
        currency: raw_account["currency"],
        iban: raw_account["iban"],
        balance: { current: raw_account["balance"] }
      )
    end

    def build_transaction(raw_movement)
      account_id = Freentonic::Canonical.account_id(
        institution: INSTITUTION,
        iban: raw_movement["account_iban"]
      )
      Freentonic::Canonical::Transaction.new(
        id: Freentonic::Canonical.transaction_id(
          account_id: account_id,
          date: raw_movement["date"],
          amount: raw_movement["amount"],
          raw_description: raw_movement["concept"]
        ),
        source_id: raw_movement["ref"],
        account_id: account_id,
        date: raw_movement["date"],
        amount: raw_movement["amount"],
        currency: raw_movement["currency"],
        raw_description: raw_movement["concept"],
        status: "posted"
      )
    end
  end
end
```

Reference from a workflow YAML:

```yaml
normalize:
  ruby: ../../my_plugin/normalizer.rb
  class: MyBank::Normalizer
```

For a fuller worked example covering multi-currency, pending vs posted,
merchant cleanup, and missing-field handling, see
[examples/normalizer.rb](../examples/normalizer.rb) and the integration
test in `test/example_workflow_integration_test.rb`.

### Things to remember

- **Always use the deterministic-ID helpers** (`Canonical.account_id`,
  `Canonical.transaction_id`, `Canonical.liability_id`,
  `Canonical.investment_id`). Hand-rolled hashes drift between syncs and
  defeat the point of stable IDs. The helpers refuse to silently produce
  drifting IDs — if your inputs can't yield a stable ID, the helper
  raises `Canonical::UnstableIdError` with a clear message.
- **Money is BigDecimal internally**, JSON strings on the wire. The
  factory accepts strings or numerics and coerces; pass `"45.20"` or
  `45.20`, not pre-formatted strings like `"€45,20"`.
- **Dates are `Date`, timestamps are `Time` UTC.** ISO strings work too;
  the factory parses them.
- **`source_id` is first-class** on every entity — keep the bank's own
  ref there even when you also compute a canonical id. It is unique
  within a single source only; never use it for cross-source joins.
- **Permissive schema:** pass `nil` for any optional field you don't
  have. Required fields per entity are spelled out in
  [canonical-data-model.md](canonical-data-model.md).

### Testing a normalizer

Normalizers are pure functions — hand-craft the smallest raw fixture
that exercises the branch you care about, assert on the output. No
stubs, no fakes, no network.

```ruby
# my_plugin/test/normalizer_test.rb
require "minitest/autorun"
require "freentonic"
require_relative "../normalizer"

class MyBankNormalizerTest < Minitest::Test
  def test_builds_canonical_payload
    raw = {
      "accounts" => [{ "ref" => "1", "alias" => "Main", "iban" => "ES01",
                       "currency" => "EUR", "balance" => "100.00" }],
      "movements" => [{ "ref" => "T1", "account_iban" => "ES01",
                        "date" => "2026-04-20", "amount" => "-10.00",
                        "currency" => "EUR", "concept" => "Coffee" }]
    }
    payload = MyBank::Normalizer.new.call(raw)

    assert_kind_of Freentonic::Canonical::CanonicalPayload, payload
    assert_equal 1, payload.accounts.length
    assert_equal 1, payload.transactions.length
    assert_match(/\Atxn_[0-9a-f]{16}\z/, payload.transactions.first.id)
  end
end
```

The real provider normalizer tests (in `freentonic-providers`)
are only a few dozen lines each and make good reference points for
larger cases — particularly for walking nested product/movement trees.

---

## Pre-submission checklist

- [ ] `register(:name, Klass)` is called at load time, not lazily.
      Otherwise `--export name` / `--secrets name` won't find you.
- [ ] Plugin raises `Freentonic::UserError` (or `Freentonic::ExportError`
      for exporters) on actionable failures — not bare `RuntimeError`.
      The CLI catches these and prints their message verbatim.
- [ ] Every user-facing error message says **what went wrong** AND
      **what to do next**. The framework-level errors are the pattern
      to match.
- [ ] No shell interpolation, no `eval`, no dynamic `const_get` off a
      string you built yourself. Follow the framework's invariants
      listed in `SECURITY.md`.
- [ ] Tests pass without network access. If your plugin hits the
      network in production, stub the boundary in tests the way
      `test/exporters_test.rb` stubs `Net::HTTP.new`.
- [ ] Tests pass under `ruby -Ilib -I<your_dir>` **without** Bundler —
      that's the mode freentonic itself runs in when loaded via a
      simple `gem install freentonic && freentonic -r your_plugin.rb`.

---

## Reference files in the framework

When you get stuck, read the shipping plugin closest to what you're
building. Each one is small (under 150 lines) and carries no surprises:

| You're writing…            | Read first                                              |
| -------------------------- | ------------------------------------------------------- |
| A file-output exporter     | `lib/freentonic/exporters/json.rb` (15 lines)           |
| A flattening file exporter | `lib/freentonic/exporters/jsonl.rb` or `csv.rb`         |
| A network exporter         | `lib/freentonic/exporters/http.rb`                      |
| An ephemeral secret store  | `lib/freentonic/secrets/cli.rb`                         |
| A persistent secret store  | `lib/freentonic/secrets/macos_keychain.rb`              |
| A file-backed secret store | `lib/freentonic/secrets/plain_file.rb` (mode checks!)   |
| A provider normalizer      | freentonic-providers' `ing/normalizer.rb`               |
| The extension loader       | `lib/freentonic/cli.rb#pre_process_requires`            |

If you think you need to modify the framework itself to make your
plugin possible, open an issue first — the three extension points are
designed to cover every real case, and most "I need to patch freentonic"
moments turn out to be solvable by reading `cli.rb` for 10 minutes.
