# Proposal — `inline_fd` secret backend (no-file transport for inline credentials)

**Status:** proposed.

**Consuming caller:** simplefreen (and any future `/invoke` caller that
ships credentials as `credentials.inline` in the request). Today this
is the only path that triggers the INSECURE banner without the
operator having opted into a long-lived plaintext dotenv.

## Problem

`/invoke` requests carrying `credentials.inline` are materialized by
`Freentonic::InvokeRunner` as a dotenv file on tmpfs and consumed
through the existing `plain_file` secret backend
(`lib/freentonic/invoke_runner.rb:112-117, 206`). That backend prints
an INSECURE banner to stderr on every build
(`lib/freentonic/cli.rb:263-266`), which is captured into the per-run
log file (`invoke_runner.rb:248`) and surfaced verbatim to operators
in simplefreen's UI:

```
⚠️  Freentonic is using the INSECURE plain_file secret backend.
Secrets are stored in plaintext. Rotate secrets stored this way and
prefer a real backend in production.
```

The banner exists for a legitimate case — a human pointing `--secrets
plain_file` at their own long-lived dotenv on disk — but it's
misleading and unactionable for the `/invoke` + inline case, where:

- The secrets file lives only on tmpfs (RAM-backed; never hits disk).
- The directory and file are created with `0700` / `0600` mode for the
  freentonic UID only.
- `InvokeRunner` removes the tmpfs directory in its `ensure` block
  regardless of how the run terminated (`invoke_runner.rb:147`).
- The caller (simplefreen) keeps the originals encrypted at rest
  (AES-GCM, master key `SIMPLEFREEN_SECRETS_KEY`) and decrypts only at
  invoke time.

There is no action a simplefreen operator can take in response to the
warning. They cannot select a different backend over `/invoke`.

## Goal

Pass inline credentials in-process through an inherited file
descriptor instead of an ephemeral tmpfs dotenv. Three concrete wins:

1. No path exists for any window — nothing to `open(2)`, nothing to
   chase if cleanup somehow fails.
2. Accurate UX: the misleading INSECURE banner stops firing on
   `/invoke`, while the CLI-with-dotenv case keeps it.
3. Simpler runner: the tmpfs scaffolding (`@tmpfs_dir`,
   `cleanup_tmpfs`, `write_secrets_file`) goes away entirely.

Threat-model honesty: this does *not* hide the secrets from anything
running as the freentonic UID (or root) — `/proc/self/fd/3` is still
drainable by the same trust principal that could have read the 0600
tmpfs file. The improvement is "no on-disk artifact, no path to
race", not "unreachable to the local UID".

## Declarative shape

New secret backend registered as `:inline_fd` (underscored to match
`:plain_file`). Invoked by the spawned child with:

```
--secrets inline_fd --secrets-fd 3
```

No `--secrets-file` argument. The child reads a dotenv-formatted
payload from fd 3 on startup, parses it into the in-memory `@values`
map (identical key shape to `plain_file`: `<source_key>.<secret_name>`
or bare `<secret_name>`), then closes the fd. The payload is never
materialized to disk.

`Cli#build_secret_store` does **not** print any banner for
`:inline_fd`. The backend is by construction memory-only, with the
same risk surface as any other env-resolved secret.

## Implementation sketch

### 1. New backend: `lib/freentonic/secrets/inline_fd.rb`

```ruby
module Freentonic
  module Secrets
    class InlineFd < Store
      def initialize(fd:)
        @values = read_dotenv_from_fd(fd)
      end

      def fetch(source_key:, secret_name:)
        scoped = "#{source_key}.#{secret_name}"
        @values[scoped] || @values[secret_name.to_s]
      end

      def prompt_and_store(source_key:, secret_name:, prompt:, stdout:, stderr:)
        raise UserError,
              "inline_fd backend cannot prompt (prompt: #{prompt})"
      end

      private

      def read_dotenv_from_fd(fd)
        io = IO.for_fd(Integer(fd), "r")
        result = {}
        io.each_line do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")
          key, val = line.split("=", 2)
          next unless key && val
          result[key.strip] = val.strip.gsub(/\A"(.*)"\z/, '\1')
        end
        result
      ensure
        io&.close
      end
    end
    register(:inline_fd, InlineFd)
  end
end
```

### 2. CLI wiring: `lib/freentonic/cli.rb`

- Add `--secrets-fd N` option (integer).
- In `build_secret_store`, branch on backend name:
  - `:plain_file` → existing behavior (banner + path).
  - `:inline_fd` → no banner, construct `InlineFd.new(fd: options[:secrets_fd])`.
- Validation matrix (each combination raises `UserError` with the
  named cause):
  - `--secrets inline_fd` without `--secrets-fd` → "inline_fd requires --secrets-fd N".
  - `--secrets inline_fd --secrets-file …` → "inline_fd does not take --secrets-file".
  - `--secrets plain_file --secrets-fd …` → "plain_file does not take --secrets-fd".
  - `--secrets-fd N` with no `--secrets` flag → "--secrets-fd requires --secrets inline_fd" (do not silently default).

### 3. `InvokeRunner` switches inline-cred path

Two coupled signature changes, then one branch in `#run`.

**`build_argv`** stops taking a `secrets_path:` and instead takes a
`secrets_arg:` describing the chosen backend:

```ruby
def build_argv(request, secrets_arg:, run_dir:)
  argv = @freentonic_cmd.dup
  argv << "--no-sandbox"
  argv.push("--workflow", request.workflow_path)
  case secrets_arg
  in [:file, path]  then argv.push("--secrets", "plain_file", "--secrets-file", path)
  in [:fd,   n]     then argv.push("--secrets", "inline_fd",  "--secrets-fd",   n.to_s)
  end
  # … (rest unchanged)
end
```

**`spawn_and_wait`** grows an `extra_fds:` kwarg that is merged into
the `Process.spawn` options hash. `close_others: true` keeps every
other inherited fd closed for the child; explicitly redirected fds
are exempt.

```ruby
def spawn_and_wait(env, argv, log_path, timeout_sec, extra_fds: {}, &on_start)
  # …
  pid = Process.spawn(
    env, *argv,
    unsetenv_others: true,
    close_others:    true,
    pgroup:          true,
    out:             log_fd,
    err:             log_fd,
    **extra_fds,
  )
  # …
end
```

**`#run`** replaces the tmpfs branch (`invoke_runner.rb:112-117`) with:

```ruby
secrets_arg = nil
extra_fds   = {}
write_io    = nil  # held so GC doesn't close it before spawn

if request.credentials_inline
  read_io, write_io = IO.pipe
  extra_fds[3] = read_io
  secrets_arg  = [:fd, 3]
else
  secrets_arg = [:file, request.credentials_file]
end

# … build env, build_argv(request, secrets_arg:, run_dir:), spawn_and_wait(…, extra_fds:)

# After spawn returns (inside spawn_and_wait, or right after it):
#   - parent closes read_io (child has its own dup)
#   - parent writes payload synchronously and closes write_io
if write_io
  read_io.close
  payload = request.credentials_inline
    .sort.map { |k, v| "#{k}=#{v}" }.join("\n")
  write_io.write(payload)
  write_io.close
end
```

Synchronous write is safe: inline payloads are O(hundreds of bytes),
far below Linux's 64KB pipe buffer, so the parent never blocks. No
writer thread, no lifecycle cleanup. Closing `write_io` is what
gives the child EOF on fd 3.

`cleanup_tmpfs` is no longer called on the inline path — there is
nothing to clean up.

### 4. Banner only for `--secrets plain_file`

Leave `Secrets::PlainFile.insecure_banner` and its emission in `cli.rb`
exactly as today. CLI users that aim `--secrets plain_file` at a
long-lived dotenv keep seeing the warning — that is the case it was
written for.

## Scope of the change

- `credentials.file` callers (operator-managed dotenv pointed at via
  `--secrets-file`) keep using `plain_file` and keep seeing the
  banner. Unchanged.
- `credentials.inline` callers move to `inline_fd` unconditionally —
  no feature flag, no fallback. The `/invoke` request schema does
  not change; simplefreen ships no client update.
- Delete in the same change: `@tmpfs_dir`, `tmpfs_dir:` constructor
  kwarg, `DEFAULT_TMPFS_DIR`, `cleanup_tmpfs`, `write_secrets_file`,
  and the tmpfs branch in `#run`. The non-inline path never touched
  tmpfs to begin with, so nothing else depends on this scaffolding.
  Per project policy: no dormant code, no phased rollout.

## Test plan

- `secrets_test.rb`: `InlineFd` parses scoped + bare keys from a real
  `IO.pipe` read end, raises `UserError` on `prompt_and_store`, and
  closes the fd after construction.
- `invoke_runner_test.rb`: on an inline-cred invoke, `@tmpfs_dir` is
  not created on disk after the run (the tmpfs scaffolding is gone,
  so its absence is a real signal); the child argv contains
  `--secrets inline_fd --secrets-fd 3`; the child receives the same
  secret values it does today (assert via a stub `freentonic_cmd`
  that echoes its parsed `@values`).
- CLI option-matrix cases, each exiting with `UserError`:
  `--secrets inline_fd` alone; `--secrets inline_fd --secrets-file …`;
  `--secrets plain_file --secrets-fd 3`; `--secrets-fd 3` with no
  `--secrets` flag.
- Regression: `--secrets plain_file --secrets-file <dotenv>` still
  prints the INSECURE banner verbatim.

## Out of scope

- New backends for production secret stores (Vault, AWS Secrets
  Manager, etc.). This proposal only addresses the inline-from-caller
  case; persistent stores remain orthogonal.
- Any change to how simplefreen encrypts at rest or how it builds the
  `/invoke` body.
- Multi-line secret values (PEM keys, etc.). The dotenv `KEY=VALUE\n`
  framing inherits the same one-line-per-value limitation that
  `plain_file` and today's tmpfs write already have. Not a regression;
  worth fixing separately if a caller hits it.
