# Freentonic

Declarative YAML-driven scraper for personal-data providers (banks,
brokers, utilities). Drives a real Chrome session over the DevTools
Protocol, captures credentials the browser collects during login, issues
authenticated API calls, normalizes the result, and exports it via
pluggable backends — all from a single YAML file plus a small amount of
provider-specific Ruby.

Freentonic has **zero runtime gem dependencies**. It's pure Ruby stdlib.

## Quickstart

```sh
gem install freentonic
git clone https://github.com/GermanDZ/freentonic-providers

# Export your last 30 days of movements as a CSV:
freentonic \
  --workflow freentonic-providers/ing/workflow.yml \
  --export csv --export-path ~/Desktop/movements.csv \
  --export-csv-select accounts.movements
```

That's it — freentonic launches Chrome, logs into your bank, fetches
your data, and writes a spreadsheet-ready CSV. On macOS, credentials
are saved in your Keychain so the next run is hands-free.

See **[docs/getting-started.md](docs/getting-started.md)** for the
full step-by-step guide covering multiple export formats, offline
iteration, and pushing to an API.

Prefer Docker? Two paths:

- **Run freentonic as a long-running HTTP server** that your web app
  drives over `/invoke` — see
  **[docs/invoke-server-deployment.md](docs/invoke-server-deployment.md)**
  and **[docs/invoke-server-api.md](docs/invoke-server-api.md)**. This
  is the recommended path for automation across multiple providers /
  credentials.
- **Run one-off workflows in a throwaway container** from your
  terminal — see **[docs/running-in-docker.md](docs/running-in-docker.md)**.

Looking to **plug freentonic into [Actual Budget](https://actualbudget.org/)** as
a SimpleFIN backend? See the sibling
[`simplefreen`](https://github.com/GermanDZ/simplefreen) project — a
SimpleFIN emulator that calls freentonic over `/invoke` and speaks the
SimpleFIN protocol to Actual.

## The pipeline

Freentonic runs every workflow through four stages. Each stage is
independently runnable and each one either reads or writes a named slot in
a shared context hash:

| Stage       | Reads              | Writes                | Effect                                                    |
| ----------- | ------------------ | --------------------- | --------------------------------------------------------- |
| `connect`   | —                  | `credentials`         | Launches Chrome, runs the YAML login pipeline, captures credentials. |
| `extract`   | `credentials`      | `raw`                 | Calls the provider API via the declared extractor class.              |
| `normalize` | `raw`              | `normalized`          | Applies the declared normalizer (Passthrough by default).             |
| `export`    | `normalized`       | —                     | Fans the normalized payload out to every `--export` declared.         |

### Stage control flags

- `--only-stage connect|extract|normalize|export` runs exactly one stage.
- `--through STAGE` runs every stage up to and including `STAGE`.
- `--dump-raw PATH` writes `context[:raw]` as pretty JSON after Extract.
- `--from-raw PATH` loads raw from disk; skips Connect + Extract entirely.
- `--dump-normalized PATH` / `--from-normalized PATH` — same, one stage later.

This is the killer feature: you can capture a raw payload once (which
requires touching the bank's login flow) and then iterate on your
normalizer code in a tight loop against the dumped JSON.

## Workflow YAML reference

```yaml
version: 1

config:
  key: example_bank           # short identifier used in secret backends & logs
  default_lookback_days: 30

# Secret references inside step values look like "secret(NAME)". The named
# entry below describes how to prompt the user the first time.
secrets:
  USER_DNI:
    prompt: "Enter your DNI"
  USER_PIN:
    prompt: "Enter your 4-digit PIN"

# Login + credential-capture pipeline. Runs inside the headed Chrome
# session. Each action is implemented by BrowserWorkflowRunner; the full
# action list is in lib/freentonic/browser_workflow_runner.rb.
pipeline: [login, capture_credentials]

phases:
  login:
    - action: navigate
      url: https://bank.example/login
    - action: wait_for_selector
      selector: "#dni"
    - action: fill
      selector: "#dni"
      value: "secret(USER_DNI)"
    - action: enter_pin_pad
      selector: ".container-pinpad"
      pin: "secret(USER_PIN)"
    - action: wait_url
      includes: /dashboard

  capture_credentials:
    - action: wait_network_idle
      seconds: 3
    - action: capture_cookie_header
      host: bank.example
      path: /
      as: cookie
    - action: capture_header
      name: X-CSRF-Token
      as: csrf_token

# Describe the credentials hash produced by the capture_credentials phase.
# `map:` transforms the workflow_context into the final credentials dict
# that downstream stages see.
credentials:
  require: [cookie]
  validate:
    - key: cookie
      not_empty: true
  map:
    - { from: cookie,     as: cookie }
    - { from: csrf_token, as: csrf_token }

# Declare a dynamically-built HTTP client. The endpoints defined here
# become methods on the client the Extract stage instantiates.
api_client:
  base_url: https://api.bank.example
  api_root: /v1
  credentials: [cookie, csrf_token]
  auth_headers:
    Cookie: "{cookie}"
    X-CSRF: "{csrf_token}"
  batch_keys: [items]
  date_format: "%Y-%m-%d"
  endpoints:
    - name: fetch_accounts
      method: GET
      path: /accounts
    - name: fetch_movements
      method: GET
      path: /accounts/{id}/movements
      params:
        from: "{from_date|date}"

# The Extract stage loads this Ruby file relative to the YAML directory
# and instantiates the named class, then calls #call(client:, credentials:,
# from_date:, stdout:, stderr:).
extract:
  ruby: ./extractor.rb
  class: ExampleBank::Extractor

# Same shape for Normalize. Normalizers subclass Freentonic::Normalizers::Base
# and implement #call(raw, context:). If omitted, Passthrough is used.
normalize:
  ruby: ./normalizer.rb
  class: ExampleBank::Normalizer
```

### Workflow action reference

Every workflow action has its own dedicated documentation page with full
option tables, behaviour notes, and examples. See
**[docs/workflow-actions.md](docs/workflow-actions.md)** for the complete
list, or jump directly to the most commonly used actions:

- [`fill`](docs/workflow-action-fill.md) / [`click`](docs/workflow-action-click.md) — interact with form inputs and buttons
- [`wait_for_selector`](docs/workflow-action-wait-for-selector.md) / [`wait_url`](docs/workflow-action-wait-url.md) — wait for page state
- [`capture_header`](docs/workflow-action-capture-header.md) / [`capture_cookie_header`](docs/workflow-action-capture-cookie-header.md) — extract credentials
- [`prompt_stdin_and_fill`](docs/workflow-action-prompt-stdin-and-fill.md) — read SMS OTP from terminal
- [`record_requests`](docs/workflow-action-record-requests.md) / [`dump_requests`](docs/workflow-action-dump-requests.md) — capture network traffic during investigation
- [`when_context`](docs/workflow-when-context.md) — conditional step execution
- [`error_signals`](docs/workflow-error-signals.md) — early abort when the bank blocks the session

## Exporters

Pass `--export NAME` one or more times. Subsequent `--export-*` flags
attach to the most-recently-declared exporter:

```
freentonic --workflow workflow.yml \
  --export json  --export-path data.json \
  --export jsonl --export-path movements.jsonl --export-csv-select accounts.movements \
  --export http  --export-url https://api.example.com/push --export-token $TOK
```

Built-in exporters:

- `json` — pretty-printed JSON to file or stdout (`--export-path -`).
- `jsonl` — one JSON object per line; `--export-csv-select accounts.movements` flattens nested collections.
- `csv` — comma-separated; same flattening semantics as jsonl.
- `http` — POSTs the payload to `--export-url`. Options: `--export-token`,
  `--export-method`, `--export-content-type`, `--export-header KEY=VAL` (repeatable).

Write your own: subclass `Freentonic::Exporters::Base`, register it with
`Freentonic::Exporters.register`, and point Freentonic at it with
`freentonic -r ./my_exporter.rb --export my_exporter ...`. The `-r` flag
is pre-processed before option parsing so your `register` call runs in
time for `--export` to find it.

## Secrets

Pass `--secrets BACKEND`. Defaults to `macos_keychain` on macOS, `cli`
elsewhere. Built-in backends:

- `cli` — ephemeral. Prompts with `noecho` each run; never persists.
- `macos_keychain` — persists via the `security` CLI. First run launches
  an Apple-native prompt; subsequent runs return silently.
- `plain_file` — dotenv file at `--secrets-file PATH`. **Insecure** — see
  [SECURITY.md](SECURITY.md). Required 0600 permissions; prints a banner
  on every use.

Custom backends subclass `Freentonic::Secrets::Store` and implement
`fetch` + `prompt_and_store`. See SECURITY.md for Linux Secret Service,
Windows Credential Manager, and 1Password skeletons.

## Running the tests

Freentonic's test suite is pure minitest. Exporter, secret-backend, and
CLI tests stub out Chrome and HTTP so nothing touches the network.

```sh
# Install dev dependencies (minitest + rake + Ruby 3.4 default gems).
bundle install

# Run the full suite.
bundle exec rake test

# Or run a single file without the rake overhead (fastest feedback loop
# while iterating on a single component).
ruby -Ilib -Itest test/exporters_test.rb
ruby -Ilib -Itest test/cli_test.rb
```

If `base64` / `csv` fail to load under Bundler, you're on Ruby 3.4+.
Those libraries moved out of the standalone stdlib into "default gems"
that Bundler refuses to autoload unless declared. The repo's Gemfile
already declares them in the dev group — just make sure you ran
`bundle install` before `bundle exec rake test`.

## Extending freentonic

Three extension points. Each is a registry-based plugin: subclass the
base, register under a name, and freentonic looks you up by that name.

- **Exporters** — new output destinations (webhook, S3, Kafka, …).
- **Secret backends** — new places to read / persist secrets (1Password,
  Linux Secret Service, Windows Credential Manager, …).
- **Normalizers** — per-provider raw → universal-shape conversion
  (normally these live in
  [freentonic-providers](https://github.com/GermanDZ/freentonic-providers)
  alongside the YAML, but the contract is the same).

See [`docs/writing-plugins.md`](docs/writing-plugins.md) for a
walkthrough of each extension point, including fixture-backed tests and
how to load your plugin via `freentonic -r ./my_plugin.rb`.

Adding an entire new **provider** belongs in
`freentonic-providers`, not here — see that repo's
[`docs/creating-a-provider.md`](https://github.com/GermanDZ/freentonic-providers/blob/main/docs/creating-a-provider.md).

## Removing freentonic data

To remove all sensitive data freentonic created on your machine:

```sh
freentonic --purge
```

This deletes:

- The Chrome profile at `~/.cache/freentonic/chrome` (cookies, session
  state, device trust)
- All macOS Keychain entries with service prefix `freentonic.`
- Any leftover temp profiles in `/tmp/freentonic-chrome-*`

You will be prompted for confirmation. Use `--force` to skip:

```sh
freentonic --purge --force
```

**Note:** Export files (JSON, CSV, etc.) at user-specified paths and
`--secrets plain_file` files are not deleted automatically — remove
those manually if they contain sensitive data.

## Security

Workflow YAMLs have the same blast radius as Ruby scripts run as your
user — they can load `ext:` Ruby, navigate Chrome with your session
cookies, and POST to arbitrary endpoints. Read
[SECURITY.md](SECURITY.md) before you run a YAML you didn't write
yourself.

## License

MIT. See [LICENSE](LICENSE).
