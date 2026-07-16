# Security

Freentonic drives a real browser against a real bank session, touches
secrets, and exports data to third-party systems. This document spells out
the threat model, the invariants the framework guarantees, and the sharp
edges you as a user need to understand.

## Trust boundary: workflow YAML is code

A workflow YAML has the same blast radius as a Ruby script running as your
user. Anyone who can write to a provider YAML can:

- Navigate Chrome to arbitrary URLs with your session cookies attached.
- Capture HTTP request headers and cookies from any site you log into.
- Issue authenticated HTTP calls against your bank using credentials that
  the browser just captured.
- Via the `api_client.ext` escape hatch (see below), load and execute
  arbitrary Ruby code from a sibling file.

**Treat workflow YAMLs and their sibling Ruby files with the same care you
would treat any other source file you run.** Don't clone an untrusted
provider repo and point `freentonic --workflow` at it without reading the
YAML and the associated extractor/normalizer/ext files first. Pin the
providers repo to a commit hash, not a branch.

## Invariants

The framework enforces the following at every release. If any of these
regresses, it's a security bug — please report it.

1. **YAML is loaded with `YAML.safe_load(permitted_classes: [], aliases: false)`.**
   Malicious `!ruby/object:...` tags will fail to parse. See
   `lib/freentonic/workflow_schema.rb`.

2. **Every JS string injected into Chrome via `Runtime.evaluate` serializes
   its arguments through `JSON.generate`.** Selector values, typed
   characters, and PIN digits never flow into JavaScript source code
   through string interpolation. See `lib/freentonic/browser_workflow_runner.rb`.

3. **`Process.spawn` is always called with the array form**, never with a
   shell string, so user-controlled values cannot be interpreted by a
   shell. Chrome flags that take values are passed as `--flag=value` so
   they survive argv splitting. See `lib/freentonic/chrome_cdp.rb`.

4. **`api_client.ext` requires an explicit `module:` name.** There is no
   dynamic `const_get` off a string interpolated from YAML. The
   `load_client_ext` implementation refuses to run unless the YAML hash
   has both `file:` and `module:` keys, and resolves the module via a
   strict nested `const_get(name, false)` walk — YAML authors cannot
   influence which Ruby constant gets resolved beyond what they type.

5. **`extract: plan:` cannot call arbitrary client methods.** The plan
   interpreter dispatches on a fixed, closed verb set (fetch / select /
   for_each / yield), and a `fetch:` step resolves its endpoint name
   against the workflow's own declared `api_client.endpoints` list —
   validated at load and re-checked at call time. There is no `send` off
   an arbitrary YAML string. A plan therefore cannot reach `raw_request`,
   `update_auth_headers!`, or any client method that isn't a declared
   endpoint; it is strictly less powerful than the `{ruby:, class:}`
   escape hatch. (This narrows blast radius *within* the "YAML is code"
   trust boundary — a plan is data, unlike a sibling `extractor.rb`.)

6. **The HTTP exporter has a token environment fallback** (`--export-token`
   → `FREENTONIC_HTTP_TOKEN`) so secrets do not need to appear in your
   shell history or process list.

7. **`prompt_stdin_and_fill` handles single-use values that are never
   persisted.** SMS OTPs and similar one-shot codes are read from an
   interactive TTY (refused on non-tty stdin), fed into the page through
   the same `fill_selector` path used by `fill` (CDP key events, never
   string-interpolated into JS), and dropped on the floor when the
   action returns. The captured value is never written to logs (not the
   value, not its length), never written to the secret backend, never
   stored on `@context`, and never resolved through `secret(...)`.

## Investigation tooling (`record_requests` / `dump_requests`)

The `record_requests` and `dump_requests` workflow actions capture raw
network traffic (request/response metadata and optionally response
bodies) to a file on disk. Treat these files with the same seriousness
as HAR captures:

1. **Never on by default.** `record_requests` must be explicitly added
   to a workflow YAML. There is no env var, CLI flag, or implicit
   capture mode.
2. **Never committed.** The `dump_requests` path is validated at runtime
   to reject paths inside `freentonic-providers` directories or inside
   the current git repo. This is a speed bump, not a guarantee — review
   diffs before committing.
3. **Never in logs.** The `[yml] record_requests` and `[yml] dump_requests`
   log lines print only the action name, pattern count, entry count, and
   output path. They never log URLs, headers, or body content.
4. **Never in stage dumps.** `context[:debug_request_log]` is excluded
   from `--dump-raw` / `--dump-normalized` output. The engine serializes
   only `:raw` and `:normalized` — an explicit allowlist.
5. **CPU/memory limits enforced.** `max_entries` and `max_body_bytes`
   have hard upper bounds (10,000 entries and 4 MB per body) validated
   at schema load time.
6. **Delete after use.** Capture files contain session cookies, auth
   tokens, and potentially PII. Delete them as soon as you've extracted
   the information you need, the same way you would rotate cookies after
   a manual HAR investigation.

## Page observation (`inspect_page` / `failures.ndjson`)

The `inspect_page` action and the `failures.ndjson` file written on a wait
timeout both persist a structured inventory of the page's visible
interactive elements. They carry element **metadata only — never element
values**.

1. **Metadata, not values.** Each entry is a selector candidate plus a
   label/role/href and, for inputs, a `type` and a `masked` boolean.
   `masked: true` records that an input *is* sensitive (a password/OTP/CVV
   field, by type/name/autocomplete heuristics) — it never carries the
   field's contents. Even a non-sensitive input's typed value is dropped.
   The observer reads only the `mask` flag from the shared selector code,
   and a Ruby-side key whitelist (`PageObserver::ALLOWED_ELEMENT_KEYS`)
   strips anything else as defense in depth.
2. **Counts, not contents, in logs.** The `[yml] inspect_page` log line
   prints only the element count and the optional context key — never a
   selector, label, or value.
3. **`failures.ndjson` is a run artifact.** On a wait timeout the runner
   appends one JSON line (timestamp, the timeout description, current
   URL/title, and the interactive inventory) to `<run_dir>/failures.ndjson`
   at mode `0600`, next to the timeout screenshot. It is written **only**
   when `FREENTONIC_RUN_DIR` points at a writable directory — there is no
   fallback to the current working directory, so it can't litter an
   arbitrary tree. The observation is fully wrapped in a rescue: a failed
   observation never masks the original timeout error.
4. **Same handling as screenshots.** A run dir holds screenshots of bank
   pages (balances, transactions, mid-flow codes). `failures.ndjson` sits
   alongside them and deserves the same care — it's URL + selectors, no
   secrets, but delete the run dir after use all the same.

## The `plain_file` secret backend is insecure

`--secrets plain_file --secrets-file PATH` reads secrets from a dotenv-
style file. It:

- Refuses to load a file whose mode is readable by group or other
  (`mode & 0o077 != 0`). This catches the most common "I chmod 644 by
  accident" foot-gun.
- Prints an INSECURE banner on every invocation so you can't forget you
  opted into it.

That's the extent of the protection. The file is still plaintext on disk,
subject to backup and process-memory disclosure. Use `macos_keychain` on
macOS, or write a custom backend (see below) that targets a real secret
manager — never ship `plain_file` to production.

## Writing a custom secret backend

Every backend is a subclass of `Freentonic::Secrets::Store` that
implements `fetch` and `prompt_and_store`. Load it via
`freentonic -r ./my_backend.rb --secrets my_backend ...`. Example
skeletons for common systems:

```ruby
# ~/my_backend.rb — 1Password CLI
class OnePasswordBackend < Freentonic::Secrets::Store
  def fetch(source_key:, secret_name:)
    stdout, _, status = Open3.capture3("op", "read", "op://freentonic/#{source_key}/#{secret_name}")
    status.success? ? stdout.strip : nil
  end

  def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
    raise Freentonic::UserError,
          "store the secret in 1Password under freentonic/#{source_key}/#{secret_name} and re-run"
  end
end
Freentonic::Secrets.register(:onepassword, OnePasswordBackend)
```

```ruby
# Linux Secret Service (via secret-tool)
class SecretToolBackend < Freentonic::Secrets::Store
  def fetch(source_key:, secret_name:)
    stdout, _, status = Open3.capture3("secret-tool", "lookup", "freentonic", "#{source_key}.#{secret_name}")
    status.success? ? stdout.strip : nil
  end

  def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
    # Prompt interactively, then persist via `secret-tool store`.
    # Implementation left as an exercise — follow the MacosKeychain pattern.
    raise NotImplementedError
  end
end
Freentonic::Secrets.register(:secret_tool, SecretToolBackend)
```

```ruby
# Windows Credential Manager (via cmdkey / PowerShell)
class CredentialManagerBackend < Freentonic::Secrets::Store
  # ... similar shape; shell out to PowerShell's Get-Credential or CredentialManager module
end
Freentonic::Secrets.register(:credential_manager, CredentialManagerBackend)
```

The shapes above are illustrative — none of them ship in the v1 gem. Load
your own file with `freentonic -r ./my_backend.rb --secrets my_backend` or
put a persistent `-r` entry in a wrapper script.

## Reporting vulnerabilities

Open a private security advisory on the freentonic GitHub repository, or
email the maintainer listed in the gemspec. Please do not open a public
issue for exploitable bugs.
