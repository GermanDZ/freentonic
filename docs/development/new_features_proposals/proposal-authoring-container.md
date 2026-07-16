# Proposal — `author` container mode: noVNC + a writable workspace for the authoring loop

**Status:** draft. The environment the other three authoring proposals
run in
([`docs/llm-workflow-authoring-review.md`](../../llm-workflow-authoring-review.md)
supporting P2 #8). Ships independently — it extends the existing
Docker plumbing and needs no code change to land its first useful
version.

**Motivation:** authoring or repairing a provider means driving the
bank's real UI by hand (record the login, watch which API call fires)
while iterating on a YAML draft. The container already has everything
needed — Xvfb, x11vnc, noVNC, `--recording`, `--interactive`, `--lint` —
but the two existing container modes both get in the way:

- **`server`** mounts workflows **read-only** and locks VNC behind a
  **per-invoke rotated password** taken from the `/invoke` body
  (`invoke_runner.rb`, `docker-entrypoint.sh:44-48`). Great for
  production; hostile to "just open a browser and let me record."
- **`cli`** is one-shot: it runs a single workflow and exits, so you
  can't record → edit → re-run in one place, and it mounts workflows
  read-only too (`docker-run-freentonic.sh:166`).

So today an author hand-assembles a bespoke `docker run` with the right
mounts, the right VNC env, and a static password — every time. This
proposal makes that a first-class mode: **one command that mounts a
writable workspace, serves noVNC on a fixed loopback port with a known
password, and drops you into an iterate loop** where recordings, dumps,
screenshots, and draft YAML all land on the host directory you mounted.

## Why this belongs in the framework

- It is pure packaging of capabilities the framework already ships
  (`--recording`, `--interactive`, `--lint`, and — once they land —
  `--compile-recording` and `--step`). The value is removing the setup
  friction, which is exactly what a framework wrapper is for.
- It is the concrete home for the LLM-authoring loop: an agent (or a
  human) points the container at a workspace, drives Chrome over noVNC,
  and runs the compile/lint/step tools against the mounted dir. Without
  it, every one of those tools needs a hand-rolled container invocation.
- The existing `docker-entrypoint.sh` already has the static-password
  VNC path (`init_vnc_passwdfile cli`) and the noVNC launcher
  (`start_vnc_stack_if_enabled`). This mode reuses both.

## Scope

### The wrapper subcommand

```sh
FREENTONIC_AUTHOR_DIR=~/providers/acme ./docker-run-freentonic.sh author
```

- Mounts `FREENTONIC_AUTHOR_DIR` **read-write** at
  `/home/freentonic/authoring` — the one directory that holds the draft
  `workflow.yml`, and receives `recording.jsonl`, request dumps,
  screenshots, and `--dump-raw` output.
- Publishes noVNC on `127.0.0.1:6080` (and raw VNC on `5900`) with a
  **known static password**: `FREENTONIC_VNC_PASSWORD` if set, else a
  random one printed to the terminal — the existing `cli`-mode behavior
  (`docker-entrypoint.sh:38-43`). No `/invoke` dance.
- Runs interactively (`-it`) and, by default, drops into a shell inside
  the container with `freentonic` on `PATH`, `FREENTONIC_RUN_DIR` and the
  working dir already pointed at `/home/freentonic/authoring`, and the
  noVNC URL printed. From there the author runs the loop directly:

  ```sh
  # inside the container:
  freentonic --recording --workflow authoring/workflow.yml   # drive the bank in noVNC; events → authoring/recording.jsonl
  freentonic --compile-recording authoring/recording.jsonl --out authoring/workflow.yml   # (proposal 2)
  freentonic --lint --workflow authoring/workflow.yml
  freentonic --step --workflow authoring/workflow.yml        # (proposal 3) try actions one at a time
  freentonic --workflow authoring/workflow.yml --through extract --dump-raw authoring/raw.json
  ```

- Keeps the container's existing hardening (`--cap-drop ALL`,
  `--security-opt no-new-privileges`), but the workspace mount is
  writable (that's the point) and the rootfs stays read-only with the
  same tmpfs set — recordings/dumps go to the mounted dir, not the
  rootfs.

### The entrypoint mode

A new `author` first-argument branch in `docker-entrypoint.sh`, sibling
to the existing `cli` branch (`docker-entrypoint.sh:110-116`):

```bash
if [ "${1:-}" = "author" ]; then
  shift
  start_xvfb
  start_vnc_stack_if_enabled cli          # static, log-printed password
  export FREENTONIC_RUN_DIR="${FREENTONIC_RUN_DIR:-/home/freentonic/authoring}"
  cd /home/freentonic/authoring 2>/dev/null || true
  if [ "$#" -gt 0 ]; then
    # `author --recording --workflow ...` — run one command, then keep the
    # container alive so noVNC stays connected for the whole session.
    ruby -I/opt/freentonic/lib /opt/freentonic/bin/freentonic --no-sandbox "$@"
  fi
  exec bash                                # iterate loop
fi
```

`FREENTONIC_RUN_DIR` pointed at the mounted dir is the key wiring: it's
already the switch that routes `recording.jsonl`, screenshots,
`events.ndjson`, and prompts into a known location
(`stages/connect.rb:477-483`, `browser_workflow_runner.rb:1135`,
`reporter.rb:32`). Setting it to the bind mount means every artifact
lands on the host, editable and inspectable, with no extra flags.

### Tier 2 (optional): a browser-facing debug console

Once `--step` and `inspect_page`
([`proposal-incremental-step-session.md`](proposal-incremental-step-session.md))
exist, the `author` container can also expose the step server
(`POST /sessions`, `/sessions/:id/step`, `/sessions/:id/page`) on a
second loopback port, so an LLM agent drives the same held-open Chrome
that the human watches over noVNC. Human and agent share one browser: the
agent steps, the human sees it happen and takes over via VNC when a step
needs a human (2FA, a captcha). That's the full co-pilot authoring loop —
but it's additive and shouldn't block the Tier-1 shell mode, which is
useful the day it lands.

## Security considerations

- **This is a developer-loop container, not the production server.** It
  deliberately trades the server's locked-down VNC for a known password
  and a writable workspace. It must stay loopback-only (`-p 127.0.0.1:…`,
  as the wrapper already does everywhere) and should print a one-line
  reminder that the noVNC port exposes a live bank session to anyone who
  can reach it.
- **The workspace holds live financial data.** `recording.jsonl`,
  request dumps, and `--dump-raw` output all capture real session
  traffic. Keep the container's `umask 0077` (`docker-entrypoint.sh:9`)
  so everything written to the bind mount is owner-only, and have the
  `author` wrapper **refuse to mount an author dir that is inside a git
  work tree** — the same guard `dump_requests` already applies to its
  output path (`debug_request_writer.rb`), so a recording can't be
  `git add`ed by reflex.
- **Credentials still never touch the workspace by default.** The
  recorder masks sensitive inputs in-page; `--dump-raw` writes API
  payloads, not login secrets. The author opts into secret handling
  explicitly (`--secrets plain_file`), and that file should live outside
  the mounted workspace.
- No new network surface beyond the two loopback ports; the rootfs stays
  read-only.

## Docs

- New `docs/authoring-in-docker.md`: the one-command author loop
  (record → compile → lint → step over noVNC), cross-linked from
  `README.md`'s Docker section (which currently lists only the two
  existing paths) and from `AGENTS.md` /
  [`freentonic-providers` `AGENTS.md`](https://github.com/GermanDZ/freentonic-providers)
  as *the* recommended provider-authoring environment.
- Extend `docker-run-freentonic.sh`'s header comment and `usage()` with
  the `author` subcommand and `FREENTONIC_AUTHOR_DIR`.

## Tests

Container wiring is shell, so coverage is mostly a smoke test plus unit
tests on the pieces it reuses:

- `test_author_dir_inside_git_worktree_is_refused` — the wrapper's guard
  (mirrors the existing `debug_request_writer` git-path test).
- `test_run_dir_env_routes_recording_to_workspace` — already implicitly
  covered by the recorder path tests; add an assertion that
  `FREENTONIC_RUN_DIR=/mnt/x` puts `recording.jsonl` under `/mnt/x`.
- A documented manual smoke check (can't run Chrome in CI): `author`
  mode starts, noVNC answers on 6080, a `--recording` session writes
  `recording.jsonl` to the mounted dir, and `--lint` runs against a draft
  in the same dir. Fold into the existing "verified against the ING flag
  set" manual checklist referenced in the hardening notes.
