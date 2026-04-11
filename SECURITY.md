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

5. **The HTTP exporter has a token environment fallback** (`--export-token`
   → `FREENTONIC_HTTP_TOKEN`) so secrets do not need to appear in your
   shell history or process list.

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
