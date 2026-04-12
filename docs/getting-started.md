# Getting Started

This guide walks you through installing freentonic, running your first
provider, and exporting your bank data as a CSV file you can open in
any spreadsheet.

## Prerequisites

- **Ruby 3.2+** — check with `ruby -v`
- **Google Chrome** — freentonic drives a real Chrome session via DevTools Protocol
- **macOS or Linux** — Windows is not tested yet

## Step 1: Install freentonic

```sh
gem install freentonic
```

Verify it's installed:

```sh
freentonic --version
```

## Step 2: Clone a provider

Freentonic is a framework — it needs a **provider** to know how to log
into your bank. Providers live in a separate repo:

```sh
git clone https://github.com/GermanDZ/freentonic-providers
```

Each provider is a directory with a `workflow.yml` (login steps), an
`extractor.rb` (API calls), and a `normalizer.rb` (data shaping).

## Step 3: Export your movements as CSV

Run freentonic with the CSV exporter. This single command will:

1. Launch Chrome and log you into your bank
2. Fetch your accounts and recent movements
3. Normalize the data into a universal format
4. Write a CSV file with one row per movement

```sh
freentonic \
  --workflow freentonic-providers/ing/workflow.yml \
  --export csv \
  --export-path ~/Desktop/movements.csv \
  --export-csv-select accounts.movements
```

On your **first run**, freentonic will prompt you for credentials
(DNI, PIN, etc.). On macOS these are saved in your Keychain so you
won't be asked again.

The `--export-csv-select accounts.movements` flag tells the CSV
exporter to flatten the nested `accounts → movements` structure into
rows — otherwise you'd get a single row with the entire JSON blob.

Open `~/Desktop/movements.csv` in your spreadsheet app. Done.

## Step 4: Try other export formats

You can export to multiple formats at once. Each `--export` flag
starts a new exporter, and subsequent `--export-*` flags apply to it:

```sh
freentonic \
  --workflow freentonic-providers/ing/workflow.yml \
  --export json  --export-path ~/Desktop/full_data.json \
  --export csv   --export-path ~/Desktop/movements.csv \
                 --export-csv-select accounts.movements \
  --export jsonl --export-path ~/Desktop/movements.jsonl \
                 --export-csv-select accounts.movements
```

This produces three files from a single login session:
- `full_data.json` — the complete normalized payload (pretty-printed)
- `movements.csv` — one row per movement, spreadsheet-ready
- `movements.jsonl` — one JSON object per movement, greppable

## Step 5: Skip the login on repeat runs

Logging into your bank takes time and triggers security events. Once
you have the data, save it and iterate offline:

```sh
# First run: log in, fetch data, save the raw payload to disk.
freentonic \
  --workflow freentonic-providers/ing/workflow.yml \
  --through extract \
  --dump-raw /tmp/bank_raw.json

# Subsequent runs: skip login entirely, re-export from the saved payload.
freentonic \
  --workflow freentonic-providers/ing/workflow.yml \
  --from-raw /tmp/bank_raw.json \
  --export csv --export-path ~/Desktop/movements.csv \
  --export-csv-select accounts.movements
```

The `--from-raw` flag loads the saved JSON and skips the Connect and
Extract stages. You can re-run the normalize + export pipeline as many
times as you want without touching the bank again.

## Step 6: Adjust the lookback period

By default, freentonic fetches the last 30 days of movements. To go
further back:

```sh
freentonic \
  --workflow freentonic-providers/ing/workflow.yml \
  --lookback-days 90 \
  --export csv --export-path ~/Desktop/movements_90d.csv \
  --export-csv-select accounts.movements
```

## Step 7: Push to an API (optional)

If you have a receiver service (personal finance app, spreadsheet
webhook, etc.), you can POST the normalized data directly:

```sh
freentonic \
  --workflow freentonic-providers/ing/workflow.yml \
  --export http \
  --export-url https://your-app.example.com/api/v1/bank_push \
  --export-token $YOUR_API_TOKEN
```

The token can also be set via the `FREENTONIC_HTTP_TOKEN` environment
variable so it doesn't appear in your shell history.

## Common flags reference

| Flag | Description |
| ---- | ----------- |
| `--workflow PATH` | Path to the provider's workflow YAML (required) |
| `--export NAME` | Add an exporter: `json`, `jsonl`, `csv`, `http` |
| `--export-path PATH` | Output file path for json/jsonl/csv exporters |
| `--export-csv-select PATH` | Flatten nested data for csv/jsonl (e.g. `accounts.movements`) |
| `--export-url URL` | Full endpoint URL for the http exporter |
| `--export-token TOKEN` | Bearer token for the http exporter |
| `--lookback-days N` | How many days of history to fetch (default: 30) |
| `--through STAGE` | Run stages up to: `connect`, `extract`, `normalize`, `export` |
| `--dump-raw PATH` | Save raw API response to disk after extract |
| `--from-raw PATH` | Load raw data from disk (skips login + fetch) |
| `--dump-normalized PATH` | Save normalized data to disk |
| `--from-normalized PATH` | Load normalized data (skips login + fetch + normalize) |
| `--secrets BACKEND` | Secret backend: `macos_keychain` (default on macOS), `cli`, `plain_file` |
| `--isolated` | Use a temporary Chrome profile (no saved state) |

## Troubleshooting

### "Chrome/Chromium not found"

Freentonic looks for Chrome at the standard install paths. Make sure
Google Chrome is installed. On Linux, `chromium` or `google-chrome`
must be in your PATH.

### "No tab matching ... found"

Chrome launched but navigated somewhere unexpected. Try running with
`--isolated` to start with a clean profile (no cached sessions or
extensions interfering).

### Keychain prompts on macOS

The first run creates a Keychain entry for each secret. You'll see an
Apple system prompt asking for permission. After that, secrets are
returned silently. If you want to avoid the Keychain entirely, use
`--secrets cli` to be prompted each run.

### "workflow wait_url timed out"

The bank's login page changed or the credentials were wrong. Chrome
stays open after a failure so you can inspect what happened. Check the
selectors in the workflow YAML against the actual page.

## What's next

- **[Workflow actions reference](workflow-actions.md)** — every action
  available in workflow YAML, with full option tables
- **[Writing plugins](writing-plugins.md)** — create custom exporters,
  secret backends, or normalizers
- **[SECURITY.md](../SECURITY.md)** — threat model, invariants, and
  sharp edges
- **[Creating a provider](https://github.com/GermanDZ/freentonic-providers/blob/main/docs/creating-a-provider.md)**
  — write your own provider for a bank not yet supported
