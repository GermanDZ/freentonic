# Implementation plan — `author` container mode (noVNC + writable workspace)

Plan for [`proposal-authoring-container.md`](../proposal-authoring-container.md).
Ground-truth verified against the working tree.

## Goal

A new `author` container mode: **one command** mounts a writable workspace,
serves noVNC on a fixed loopback port with a known static password, and
drops into an iterate shell where `--recording` / `--lint` (and, once they
exist, `--compile-recording` / `--step`) run against the mounted dir. All
artifacts — `recording.jsonl`, screenshots, `events.ndjson`, prompts,
`--dump-raw` output, draft YAML — land on the host directory the author
mounted. It is pure packaging of capabilities the framework already ships;
it removes the hand-rolled `docker run` an author assembles today.

## Sequencing

Ships **independently** and needs no code change to land its first useful
version — Tier-1 works with the **existing** `--recording`/`--interactive`/
`--lint`. But it is **most useful after** `--compile-recording` (plan 2)
and `--step` (plan 3) land, since the loop's inner commands are exactly
those. **Correction vs. proposal:** the proposal's inner-loop examples call
`freentonic --compile-recording` and `freentonic --step`, which **do not
exist yet** — the author-mode doc/examples must only promise what's
currently implemented and add the other two as they land.

## Ground truth (verified anchors)

### `docker-entrypoint.sh` (141 lines)

- `umask 0077` at **9** (owner-only artifacts on bind mounts — keep it).
- `init_vnc_passwdfile(mode)` at **35-56**: `cli` + `FREENTONIC_VNC_PASSWORD`
  set → use env value (**38-39**); `cli` + no env → random 12-char printed
  (**40-43**); else (server) → 64-hex unreachable sentinel (**44-48**).
- `start_vnc_stack_if_enabled(mode)` at **60-86**: gated on
  `FREENTONIC_VNC=1`; starts `x11vnc` on display :99 with
  `-passwdfile read:$VNC_PASSWORD_FILE` (67) and `novnc_proxy ... --listen
  6080` (72-75). **noVNC port 6080 and raw VNC 5900 are hardcoded.** In
  `cli` mode it echoes the password (80-85).
- `start_xvfb` at **100-105** (clears stale `/tmp/.X99-lock`, starts Xvfb,
  exports `DISPLAY=:99`).
- **Mode dispatch:** the only special first-arg branch is `cli` at
  **110-116** (`start_xvfb` → `start_vnc_stack_if_enabled cli` → `exec ruby
  ... bin/freentonic --no-sandbox "$@"`). Everything after 116 is the
  default server path (118-140). An `author` branch slots in **before line
  118**, sibling to the `cli` block.

### `docker-run-freentonic.sh` (211 lines)

- Header comment 1-27; `usage()` 196-199 (prints header via `sed`);
  subcommand `case` **201-210** (`server`/`stop`/`logs`/`invoke`/`cli`).
- `cmd_server` (**46-125**) holds the **full hardening set**:
  `-p 127.0.0.1:...` loopback publish (59), workflows `:ro` (60), writable
  runs mount (61), chrome-profile volume (62), `--shm-size=256m` (63),
  `--cap-drop ALL` (68), `--security-opt no-new-privileges` (69),
  `--read-only` (79) + tmpfs set `/tmp`, `/home/freentonic/.config`,
  `.local`, `.pki` (80-83). VNC ports published conditionally (109-115).
- `cmd_cli` (**152-194**) is the closer analog but **simpler and
  un-hardened** (no `--cap-drop`/`--read-only`/tmpfs): mounts CWD RW at
  `/workspace` (165), workflows `:ro` at 166, `-it` via `tty_flag` + `-i`
  (160-164), VNC block 171-177, secrets 179-190, final
  `args+=("${IMAGE_NAME}" cli "$@")` (192) passing the literal `cli` first
  arg the entrypoint matches.
- **`FREENTONIC_VNC_PASSWORD` is NOT forwarded by the wrapper today** —
  only `FREENTONIC_VNC=1` is passed via `-e` (113/175). For a known static
  password, the `author` arm must add `-e "FREENTONIC_VNC_PASSWORD=..."`
  explicitly (the entrypoint already honors it in `cli`/`author` mode).

### `FREENTONIC_RUN_DIR` routing (the key wiring — confirmed)

Setting it to a bind-mounted dir routes **every** artifact there:
- `recording.jsonl` → `stages/connect.rb:476-483` (`install_recorder`).
- screenshots → `browser_workflow_runner.rb:1135-1149` (0600).
- `events.ndjson` → `reporter.rb:32-39` (0600).
- prompts → `browser_workflow_runner.rb:843-850`
  (`RemotePromptStore.new(prompts_dir: File.join(run_dir, "prompts"))`).
The server sets it per run (`invoke_runner.rb:205`). So: point
`FREENTONIC_RUN_DIR` at a dir inside the RW author mount and all artifacts
land on the host, editable and inspectable, with no extra flags.

### Git-worktree refusal to mirror

`debug_request_writer.rb#validate_path!` (37-54) + `detect_git_root`
(56-66). **Detects a `.git` directory only** (walks up from `Dir.pwd`); a
linked git *worktree* (whose `.git` is a file) is **not** caught. The
proposal wants the `author` wrapper to refuse a workspace inside a git work
tree — do it in shell with `git -C "$dir" rev-parse --is-inside-work-tree`
(catches both classic repos and linked worktrees), not by copying the
Ruby guard's `.git`-dir check.

### Docs + existing flags

- README Docker section (**34-43**) lists exactly two paths (server +
  one-off cli). `author` adds a third bullet.
- `docs/running-in-docker.md` (172 lines) is the template for a new
  `docs/authoring-in-docker.md`.
- AGENTS.md here is framework-side and defers provider *authoring* to
  `freentonic-providers/AGENTS.md` — the author-mode doc is the natural
  cross-link target from both.
- Existing reusable flags: `--recording` (`cli.rb:137`), `--interactive`
  (136), `--lint` (131). **`--compile-recording`/`--step` do not exist.**

## Implementation steps

### 1. Entrypoint `author` branch — `docker-entrypoint.sh` (before line 118)

```bash
if [ "${1:-}" = "author" ]; then
  shift
  start_xvfb
  start_vnc_stack_if_enabled cli          # static, log-printed password path
  export FREENTONIC_RUN_DIR="${FREENTONIC_RUN_DIR:-/home/freentonic/authoring}"
  cd /home/freentonic/authoring 2>/dev/null || true
  if [ "$#" -gt 0 ]; then
    ruby -I/opt/freentonic/lib /opt/freentonic/bin/freentonic --no-sandbox "$@"
  fi
  exec bash                                # iterate loop
fi
```

Reuses the `cli` static-password VNC path and the noVNC launcher verbatim.
`FREENTONIC_RUN_DIR` pointed at the mount is the whole trick.

### 2. Wrapper `cmd_author` + `case` arm — `docker-run-freentonic.sh`

- Add `author) shift; cmd_author "$@" ;;` to the `case` (201-210).
- `cmd_author`:
  - Require `FREENTONIC_AUTHOR_DIR`; `File`-expand it; **refuse if it is
    inside a git work tree** (`git -C rev-parse --is-inside-work-tree`) —
    with a clear error, mirroring the `dump_requests` ethos.
  - Mount it **read-write** at `/home/freentonic/authoring`.
  - Publish `-p 127.0.0.1:6080:6080` and `-p 127.0.0.1:5900:5900`, set
    `-e FREENTONIC_VNC=1`, and **explicitly forward the password**:
    `-e "FREENTONIC_VNC_PASSWORD=${FREENTONIC_VNC_PASSWORD}"` when set (else
    the entrypoint prints a random one).
  - Run interactively (`-it`).
  - **Keep the hardening set** from `cmd_server` (`--cap-drop ALL`,
    `--security-opt no-new-privileges`, `--read-only` rootfs + the same
    tmpfs set, `--shm-size=256m`) — but the **workspace mount is writable**
    (that's the point) and `FREENTONIC_RUN_DIR` routes artifacts to it, so
    the read-only rootfs is preserved. *Decision:* `cmd_cli` today is
    un-hardened; `author` should follow `cmd_server`'s hardening, not
    `cmd_cli`'s laxity, because it holds live financial data on a writable
    mount. Confirm this posture with the user.
  - Pass the literal `author` first arg: `args+=("${IMAGE_NAME}" author "$@")`.
  - Print a one-line reminder that the noVNC port exposes a live bank
    session to anyone who can reach it, plus the noVNC URL.

### 3. Header/usage docs in the wrapper

Extend the header comment and `usage()` (196-199) with the `author`
subcommand and `FREENTONIC_AUTHOR_DIR` / `FREENTONIC_VNC_PASSWORD`.

### 4. Tier 2 (optional, deferred) — shared step server

Once `--step` + `/sessions` (plan 3) exist, the `author` container can also
publish the step server on a second loopback port so an LLM agent drives
the same held-open Chrome the human watches over noVNC (the co-pilot loop).
**Additive; must not block Tier 1.** Track as a follow-up gated on plan 3.

## Security considerations (from the proposal, verified)

- Developer-loop container, **not** the production server: it trades the
  server's rotated VNC for a known password + writable workspace. Stay
  loopback-only (`-p 127.0.0.1:...` — the wrapper already does this
  everywhere) and print the live-session reminder.
- The workspace holds live financial data (`recording.jsonl`, dumps,
  `--dump-raw`). Keep `umask 0077` (entrypoint:9) so bind-mount writes are
  owner-only, and **refuse an author dir inside a git work tree** so a
  recording can't be `git add`ed by reflex.
- Credentials still never touch the workspace by default (recorder masks
  in-page; `--dump-raw` is API payloads, not login secrets). Secret files
  stay outside the mount (`--secrets plain_file` opt-in).
- No new network surface beyond the two loopback ports; rootfs stays
  read-only.

## Tests

Container wiring is shell, so coverage is a smoke test plus unit tests on
reused pieces (AGENTS.md invariant 10: no Chrome in CI):

- `test_author_dir_inside_git_worktree_is_refused` — the wrapper's guard
  (mirror the `debug_request_writer` git-path test; here it's a shell-level
  check, so test via a small harness that runs `cmd_author`'s guard logic,
  or factor the guard into a testable function).
- `test_run_dir_env_routes_recording_to_workspace` — assert
  `FREENTONIC_RUN_DIR=/mnt/x` puts `recording.jsonl` under `/mnt/x`
  (largely covered by existing recorder-path tests; add the explicit
  assertion).
- **Manual smoke check** (documented, can't run Chrome in CI): `author`
  mode starts, noVNC answers on 6080, a `--recording` session writes
  `recording.jsonl` to the mounted dir, `--lint` runs against a draft in
  the same dir. Fold into the existing "verified against the ING flag set"
  manual checklist in the hardening notes.

## Docs

- New `docs/authoring-in-docker.md`: the one-command author loop (record →
  lint today; + compile → step as they land) over noVNC. Cross-link from
  README's Docker section (add the third bullet) and from both AGENTS.md
  files as the recommended provider-authoring environment.
- **Only document commands that exist.** Mark `--compile-recording` /
  `--step` steps as "when available" until plans 2/3 ship.

## Risks / decisions

- **Hardening posture** — recommend `author` inherits `cmd_server`'s
  hardening (writable workspace mount is the only relaxation), not
  `cmd_cli`'s un-hardened shape. Confirm.
- **Password forwarding** — the wrapper doesn't forward
  `FREENTONIC_VNC_PASSWORD` today; the `author` arm must add it. Without a
  set password the entrypoint prints a random one (acceptable default).
- **Inner-loop commands** partly don't exist yet — the doc/examples must
  not promise `--compile-recording`/`--step` before they land.
- **Worktree detection** — use `git rev-parse --is-inside-work-tree`, not
  the Ruby guard's `.git`-dir-only walk.

## Completion checklist (AGENTS.md-adapted)

- [ ] `bundle exec rake test` green (only the reused-piece unit tests are
      new; shell wiring is smoke-tested manually).
- [ ] Manual smoke check performed and recorded in the hardening checklist.
- [ ] `docker-run-freentonic.sh` header/usage + README Docker section +
      new `docs/authoring-in-docker.md` updated.
- [ ] Loopback-only publish preserved; `umask 0077` and read-only rootfs
      preserved; git-worktree refusal in place.
- [ ] Branch handed back; no PR/push by the agent.

**Estimated effort:** ~1 day for Tier 1 (entrypoint branch + wrapper arm +
doc + the two unit tests + a manual smoke run). Tier 2 (shared step server
port) is a follow-up gated on plan 3.
