# Authoring a provider in Docker (`author` mode)

Building or repairing a provider means driving the bank's real UI by hand —
record the login, watch which API call fires — while iterating on a YAML
draft. `author` mode is the container that loop runs in: **one command**
mounts a writable workspace, serves noVNC on a fixed loopback port with a
known password, and drops you into a shell where the whole
**record → compile → lint → step** loop runs against the mounted dir.

It is pure packaging of capabilities the framework already ships
(`--recording`, `--compile-recording`, `--lint`, `--step`,
`--interactive`). The value is removing the bespoke `docker run` an author
otherwise hand-assembles every time.

> **How it differs from the other two modes.** `server`
> ([invoke-server-deployment.md](invoke-server-deployment.md)) mounts
> workflows **read-only** and locks VNC behind a per-invoke rotated password
> — great for production, hostile to "just open a browser and let me
> record." `cli` ([running-in-docker.md](running-in-docker.md)) is
> **one-shot**: it runs a single workflow and exits, so you can't
> record → edit → re-run in one place. `author` keeps **one container
> alive** with a **writable** workspace and a **static** VNC password.

---

## Prerequisites

- **Docker Desktop** (macOS/Windows) or Docker Engine (Linux).
- The image built (`docker build -t freentonic:latest .`). **`author` mode is
  baked into the image entrypoint** — if you built the image before this mode
  existed (or changed `docker-entrypoint.sh`), rebuild. A stale image silently
  falls through to *server* mode: you'll see `[invoke-server] listening …` and
  a per-invoke VNC password instead of `[entrypoint] author mode:` and a shell.
- A workspace directory on your host that is **not inside a git work tree**
  — `author` refuses one that is, so a `recording.jsonl` full of live
  session data can't be `git add`ed by reflex. Author in a scratch dir, then
  copy the finished `workflow.yml` into your provider repo.

## Step 1 — Start the authoring container

```sh
mkdir -p ~/authoring/acme          # a scratch dir, NOT inside a git repo
FREENTONIC_AUTHOR_DIR=~/authoring/acme \
FREENTONIC_VNC_PASSWORD=choose-your-own \
  ./docker-run-freentonic.sh author
```

This mounts `~/authoring/acme` **read-write** at
`/home/freentonic/authoring`, publishes noVNC on `127.0.0.1:6080` (and raw
VNC on `5900`), and drops you into a shell inside the container with:

- `FREENTONIC_RUN_DIR` and the working dir both pointed at
  `/home/freentonic/authoring`, so every artifact — `recording.jsonl`,
  screenshots, `events.ndjson`, `failures.ndjson`, prompts — lands on the
  host workspace with no extra flags;
- the noVNC URL printed, so you can watch Chrome drive the bank.

Leave `FREENTONIC_VNC_PASSWORD` unset and the container generates a random
12-char password and prints it once — grep the terminal for
`[entrypoint]   Password:`.

## Step 2 — The loop, inside the container

The shell starts in `/home/freentonic/authoring`, so the paths below are
relative to your mounted workspace. This is the container-side quick
reference; the full step-by-step (selector review, `--step`, known
limitations) is in
**[authoring-a-workflow.md](authoring-a-workflow.md)**.

```sh
# 0. Bootstrap a stub workflow if you don't have one (prompts for the URL).
freentonic --init

# 1. Record: launch Chrome at the workflow's initial URL, walk the bank's
#    login by hand in noVNC. Click/fill/submit/navigate events are captured
#    to recording.jsonl (credential fields masked in-page). Ctrl-C when done.
#    Add --reset-profile to force a bank's FULL-entry login (a persistent
#    profile that "remembers" you skips the identifier/username step).
freentonic --recording --reset-profile --workflow workflow.yml

# 2. Compile the recording into a draft connect: pipeline.
freentonic --compile-recording recording.jsonl --out workflow.yml

# 3. Lint the draft.
freentonic --lint --workflow workflow.yml

# 4. Step through it one action at a time against a held-open session —
#    a wrong selector costs one step, not a full re-login.
freentonic --step --workflow workflow.yml

# Inspect a raw API payload the workflow captures:
freentonic --workflow workflow.yml --through extract --dump-raw raw.json
```

`--compile-recording` writes a **draft, not a finished provider** — read it,
fix the selectors and `# REVIEW:` lines, then re-lint. Because the
wrapper refuses an `FREENTONIC_AUTHOR_DIR` inside a git work tree, `--out
workflow.yml` writes safely into the workspace (the `--out` guard that
normally refuses a git work tree is satisfied here by construction).

### Recording artifacts

A `--recording` session writes, in the workspace:

- `recording.jsonl` — one event per line (click/fill/submit/navigate) with
  the selector each interaction resolved to.
- `dom/<session>/NNNN.html` — a per-step DOM+shadow snapshot, one folder per
  recording session (on by default in author
  mode; `FREENTONIC_RECORD_DOM=0` to skip). Each file is the page **as the
  step acted on it**, with open shadow roots serialized as declarative
  `<template shadowrootmode="open">`. Attributes are **allowlisted** — only
  selector hooks survive (`id`, `name`, `class`, `type`, `role`,
  `placeholder`, `aria-label`, `data-testid`, `for`, `slot`, `part`, …), so
  a value a custom element reflects onto itself (`value`, `aria-valuetext`,
  `data-*`) never lands in the file, and `href` keeps only its path. This is
  the offline signal for mining a stable selector when the compiler's pick is
  a fragile auto-generated id — grep the snapshot for the element and read its
  `name` / `placeholder` / `aria-label` (the stable hooks a web-component
  login often hides behind a per-render id). The `dom_ref` field on each JSONL
  line points at the snapshot.

Both hold live page structure, so they inherit the workspace's `umask 0077`
(owner-only) and the wrapper's git-work-tree refusal. Input values and the
text inside `contenteditable` regions are stripped from the DOM snapshots. A
PIN-keypad press is recorded without its digit, and after the first one no
step on that page is snapshotted. Other text a page renders is kept, though:
labels, post-login balances and names, and anything a component echoes into
the page as you type. Treat `dom/` as sensitive, and delete the workspace
when you're done.

You can also pass the first command straight through the wrapper, then keep
iterating in the shell it leaves you in:

```sh
FREENTONIC_AUTHOR_DIR=~/authoring/acme ./docker-run-freentonic.sh author \
  --recording --workflow workflow.yml
```

A non-zero exit from that first command (a failed lint, a bad selector) does
**not** tear the container down — you land in the shell either way.

## Watching over noVNC

Two ways to attach while the container runs:

- Browser (no client install):
  `http://localhost:6080/vnc.html#host=localhost&port=6080&password=<yours>&autoconnect=true`
  (after `#`, the fragment: noVNC reads it, but it's never sent to a server
  or written to its logs; or leave `password=` out and type it at the prompt)
- Native macOS client: `open vnc://localhost:5900`, then enter the password.

VNC's wire auth truncates to 8 bytes — pick a password with real entropy in
those first 8 chars.

## Secrets

`author` mode does not auto-wire secrets. For a recording pass you type
credentials into the bank UI by hand (they're masked in the recording). When
a workflow step needs a `secret(...)`, pass a plain-text secrets file that
lives **outside** the mounted workspace, e.g. by mounting it read-only with a
bespoke `docker run` — see [running-in-docker.md](running-in-docker.md#secrets)
for the `--secrets plain_file --secrets-file …` shape. Keeping the secrets
file out of the workspace keeps credentials off the bind mount.

## Chrome profile

Author mode keeps Chrome's profile **inside your workspace** at
`~/authoring/acme/.chrome-profile` (via `FREENTONIC_CHROME_PROFILE_DIR`, set by
the entrypoint). It does **not** use the shared `freentonic-chrome-profile`
named volume that `cli`/`server` use. Two reasons:

- **Always writable.** The workspace is a bind mount, writable regardless of
  the container's uid, so author mode can't hit the shared volume's
  stale-ownership crash (see Troubleshooting).
- **Per-provider, on the host.** Each workspace keeps its own cookies / 2FA
  device-trust / session state, and it persists across container restarts
  because it lives on your Mac. Reset it by deleting the dir:
  `rm -rf ~/authoring/acme/.chrome-profile`.

Because the profile now holds a live logged-in session, it's covered by the
same rules as the rest of the workspace: `umask 0077` (owner-only) and the
git-work-tree refusal (so it can't be committed).

## Security

- **Developer-loop container, not the production server.** It deliberately
  trades the server's rotated VNC for a static password and a writable
  workspace. It stays **loopback-only** (`-p 127.0.0.1:…`) and prints a
  reminder that the noVNC port exposes a **live bank session** to anyone who
  can reach it. Don't forward those ports off `localhost`.
- **The workspace holds live financial data.** `recording.jsonl`, request
  dumps, and `--dump-raw` output capture real session traffic. The
  container's `umask 0077` keeps everything written to the bind mount
  owner-only, and the `docker-run-freentonic.sh author` wrapper **refuses a
  workspace inside a git work tree** so a recording can't be committed by
  reflex. (A raw `docker run … author` doesn't check — mount a directory
  outside any repo.)
- **Same hardening as `server`.** `--cap-drop ALL`,
  `--security-opt no-new-privileges`, and a **read-only rootfs** with the same
  tmpfs set. The only relaxation is the writable workspace mount (that's the
  point); artifacts route there via `FREENTONIC_RUN_DIR`, so the rootfs stays
  immutable.
- No new network surface beyond the two loopback VNC ports.

## Running without the wrapper

```sh
export FREENTONIC_VNC_PASSWORD=choose-your-own   # passed by name, not in argv
docker run --rm -it \
  -v "$HOME/authoring/acme:/home/freentonic/authoring" \
  --shm-size=256m \
  --cap-drop ALL --security-opt no-new-privileges \
  --read-only \
  --tmpfs /tmp --tmpfs /home/freentonic/.config \
  --tmpfs /home/freentonic/.local --tmpfs /home/freentonic/.pki \
  -p 127.0.0.1:6080:6080 -p 127.0.0.1:5900:5900 \
  -e FREENTONIC_VNC=1 -e FREENTONIC_VNC_PASSWORD \
  freentonic:latest \
  author
```

The literal `author` after the image name tells the entrypoint to start
Xvfb + noVNC with a static password, point `FREENTONIC_RUN_DIR` at
`/home/freentonic/authoring`, default `FREENTONIC_CHROME_PROFILE_DIR` to
`.chrome-profile` inside the workspace, and drop into the iterate shell. No
`freentonic-chrome-profile` volume — author mode keeps its profile in the
workspace mount.

## Troubleshooting

**Recording hangs at `Waiting for Chrome debug port…`, then fails after 45s.**
Chrome is crashing on launch (its stderr goes to `/dev/null`, so the CLI only
sees the timeout). Reproduce it with the error visible — in the container:

```sh
/usr/lib/chromium/chromium --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --user-data-dir="${FREENTONIC_CHROME_PROFILE_DIR:-/home/freentonic/authoring/.chrome-profile}" \
  --remote-debugging-port=9444 about:blank
```

Three common causes:

- **Missing `--no-sandbox`.** The container drops all capabilities, so
  Chrome's sandbox cannot start; without the flag Chrome dies before opening
  the debug port (it may still write a few profile files first, which makes
  this look like a profile problem — it isn't). The author container exports
  `FREENTONIC_NO_SANDBOX=1` so every `freentonic` invocation defaults to
  sandbox-less; on an older image, pass `--no-sandbox` explicitly. If your
  manual reproduce command *works* but `freentonic` hangs, compare sandbox
  flags first.
- **`Failed to create …/SingletonLock: Permission denied` / `Failed to create
  a ProcessSingleton`.** Chrome can't write its profile dir. Author mode keeps
  the profile in the writable workspace (`~/authoring/acme/.chrome-profile`) to
  avoid this, so it shouldn't happen here — if it does, the dir has a stray root-
  owned file: `rm -rf ~/authoring/acme/.chrome-profile` and retry. (The classic
  form of this bug is the shared `freentonic-chrome-profile` volume that
  `cli`/`server` use going stale after the image's pinned uid changes; reset it
  with `docker volume rm freentonic-chrome-profile` while no container holds it.)
- **`DISPLAY` is empty** (headed Chrome can't find the X server). The primary
  `author` shell inherits `DISPLAY=:99`; a `docker exec` shell only gets it
  because the image now bakes `ENV DISPLAY=:99` and `author-shell` passes it
  explicitly. On an older image, `export DISPLAY=:99` in the shell first.

The `dbus`/`Fontconfig error: No writable cache directories` lines Chrome
prints are harmless container noise, not the cause.
