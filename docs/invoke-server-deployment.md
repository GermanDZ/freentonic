# Deploying the Invoke Server

This guide walks you through building the freentonic image and running
the long-lived invoke-server container that your web app will call to
synchronize providers.

For the HTTP API reference, see [**invoke-server-api.md**](invoke-server-api.md).
For the legacy single-shot CLI path, see [running-in-docker.md](running-in-docker.md).

---

## What you get

A single container that:

- Listens on `http://127.0.0.1:7878/invoke` (by default) and runs a
  freentonic workflow per request.
- Serializes all invokes under a global mutex (one workflow at a time).
- Reuses a Chrome profile per `(workflow, credential-set)` pair so
  device-trust and cookies persist across runs.
- Writes per-run artifacts (screenshots, logs) under `/workspace/runs/<run_id>/`,
  which you bind-mount to a host directory. The web app reads files
  directly from that host directory.
- Passes credentials in-process through an inherited pipe (the
  child's `inline_fd` secret backend) and the API token through a
  child-only environment variable — neither touches disk and neither
  appears in `ps` output or argv.

Non-goals for v1: parallelism across tenants, log streaming, metrics.
See the plan file for the full follow-up list.

---

## Prerequisites

- **Docker 20.10+** (Linux, macOS, or Windows with WSL2).
- **A workflows directory** on the host with your provider YAMLs. Example:
  `~/freentonic/workflows/ing/workflow.yml`, `~/freentonic/workflows/revolut/workflow.yml`.
- **A runs directory** on the host where per-run artifacts will accumulate:
  `~/freentonic/runs/`. Readable by the web app.
- **A bearer token** (any hard-to-guess string) that the web app will
  send on every request.

---

## Step 1 — Build the image

```sh
git clone https://github.com/GermanDZ/freentonic
cd freentonic
docker build -t freentonic:latest .
```

The image is based on `ruby:3.2-slim-bookworm` and bundles Chromium,
Xvfb, x11vnc, and tini. It weighs ~500 MB. Zero runtime gem
dependencies are added — freentonic stays pure stdlib.

---

## Step 2 — Start the server

The wrapper script is the fastest path:

```sh
export FREENTONIC_WORKFLOWS_DIR=~/freentonic/workflows
export FREENTONIC_RUNS_DIR=~/freentonic/runs
export FREENTONIC_INVOKE_TOKEN=$(openssl rand -hex 32)
echo "$FREENTONIC_INVOKE_TOKEN" > ~/.freentonic-invoke-token  # remember it

./docker-run-freentonic.sh server
```

You should see:

```
starting freentonic-server (workflows=/Users/you/freentonic/workflows, runs=/Users/you/freentonic/runs)
<container_id>
listening on http://127.0.0.1:7878
```

Smoke-test the health endpoint:

```sh
curl -sS http://127.0.0.1:7878/healthz
# {"ok":true,"in_flight":0,"shutting_down":false}
```

The server is now accepting invokes. See the [API
doc](invoke-server-api.md) for what to send.

---

## Step 3 — Raw `docker run` (for other orchestrators)

The wrapper is a convenience; any orchestrator can start the container
directly. The full command the wrapper runs is:

```sh
docker run -d \
  --name freentonic-server \
  --restart unless-stopped \
  -p 127.0.0.1:7878:7878 \
  -v "$FREENTONIC_WORKFLOWS_DIR:/home/freentonic/workflows:ro" \
  -v "$FREENTONIC_RUNS_DIR:/workspace/runs" \
  -v "freentonic-chrome-profile:/home/freentonic/.cache/freentonic/chrome" \
  --shm-size=256m \
  -e "FREENTONIC_INVOKE_TOKEN=$FREENTONIC_INVOKE_TOKEN" \
  freentonic:latest
```

Notes:

- **`-p 127.0.0.1:7878:7878`** — only the host's loopback can reach the
  server. If your web app runs on the same host, this is what you want.
  If it runs in another container, put both containers on the same Docker
  network and drop the `-p` (publish nothing to the host). If it runs on
  another machine, terminate TLS + auth upstream (nginx, a VPN, etc.)
  and publish on the shared interface.
- **`--shm-size=256m`** — Chrome needs more than Docker's default 64 MB
  of shared memory.
- **`freentonic-chrome-profile`** is a named Docker volume. The image
  creates subdirectories inside it, one per `profile_key`.
- **Workflows mount is `:ro`**. The container should not be able to
  modify the source of truth for your workflows.

---

## Step 4 — Layout and permissions

```
host:
  ~/freentonic/workflows/          (read-only mount → /home/freentonic/workflows)
    acme/
      workflow.yml
      extractor.rb
      normalizer.rb
    bank_b/
      workflow.yml
    ...

  ~/freentonic/runs/               (read-write mount → /workspace/runs)
    <run_id_A>/
      log
      evidence-timeout-20260421-123457-412.png
    <run_id_B>/
      log
      ...

docker volume freentonic-chrome-profile:
  /home/freentonic/.cache/freentonic/chrome/
    acme__tenant42/                ← one dir per profile_key
      Cookies, Preferences, ...
    acme__tenant99/
    bank_b__tenant42/
```

**Host ownership**: the container runs as UID `freentonic` (non-root).
On Linux the UID/GID inside the container may not match the host user.
If you see permission errors when the web app tries to read
`~/freentonic/runs/<run_id>/log`, either:

- `chmod -R a+rX ~/freentonic/runs/` on the host, OR
- use the same UID inside and outside the container (pass `--user
  $(id -u):$(id -g)` to `docker run` and adjust Dockerfile accordingly —
  not needed on Docker Desktop for Mac since it automatically maps
  ownership).

**Don't delete** `~/freentonic/runs/<run_id>/` until the web app has
read it. The server never cleans up this directory — it's host-owned.

---

## Step 5 — Environment variables

`FREENTONIC_INVOKE_TOKEN` is required when starting via the
`./docker-run-freentonic.sh server` wrapper (it exits with an error
if unset). If you're spawning the container with raw `docker run`
and explicitly want OPEN mode for local dev, leave it unset — the
server binary will start and log a loud warning on every boot.
Everything else below is optional.

| Variable | Default | Purpose |
|---|---|---|
| `FREENTONIC_INVOKE_TOKEN` | *(wrapper: required; raw `docker run`: unset → OPEN mode with warning)* | Bearer token required on `/invoke`, `/status`, `/cancel/:id`, `/profiles/prune`, `/runs/:id/log`. In OPEN mode the server accepts every request without auth — never do this in production. |
| `FREENTONIC_LISTEN_ADDR` | `0.0.0.0` inside the container | Interface to bind. Override to `127.0.0.1` only if you're running freentonic outside a container. |
| `FREENTONIC_LISTEN_PORT` | `7878` | Port inside the container. |
| `FREENTONIC_WORKFLOWS_DIR` | `/home/freentonic/workflows` | Workflow root inside the container. The `/invoke` request's `workflow` field is resolved against this path. |
| `FREENTONIC_RUNS_DIR` | `/workspace/runs` | Per-run artifact root inside the container. |
| `FREENTONIC_CHROME_PROFILE_ROOT` | `/home/freentonic/.cache/freentonic/chrome` | Chrome profile parent. Subdirectories are created per `profile_key`. |
| `FREENTONIC_VNC_PASSWORD_FILE` | `/dev/shm/freentonic/vnc-password` | Tmpfs path that x11vnc reads with `-passwdfile read:` and the server rotates per-invoke. Rarely worth overriding. |
| `FREENTONIC_VNC` | `1` | Starts x11vnc on `:5900` and noVNC on `:6080`. No container-wide default password — in server mode the password comes from each `/invoke`'s `vnc_password`; in `cli` mode it comes from `FREENTONIC_VNC_PASSWORD` (below) or a random value printed on startup. See [Step 8](#step-8--debugging-with-vnc). |
| `FREENTONIC_VNC_PASSWORD` | *(none — random if unset)* | **cli mode only.** Static VNC password for the `cli` container's lifetime. Ignored in server mode. |

The wrapper script `docker-run-freentonic.sh` also reads:

| Wrapper env | Default | Purpose |
|---|---|---|
| `FREENTONIC_IMAGE` | `freentonic:latest` | Image tag to launch. |
| `FREENTONIC_CONTAINER_NAME` | `freentonic-server` | `docker run --name`. |
| `FREENTONIC_CHROME_PROFILE_VOLUME` | `freentonic-chrome-profile` | Named volume for Chrome profiles. |

---

## Step 6 — Managing the container

```sh
./docker-run-freentonic.sh server    # start in background
./docker-run-freentonic.sh logs       # follow logs (Ctrl-C to detach)
./docker-run-freentonic.sh stop       # stop and remove
```

Or equivalently:

```sh
docker logs -f freentonic-server
docker restart freentonic-server
docker stop freentonic-server
```

**Graceful shutdown**: `docker stop` sends SIGTERM. The server closes
its listener (new connections are refused — the socket is gone, so
clients see a connection error rather than a `503`), then **SIGTERMs the
in-flight invoke's Chrome/freentonic process group and waits up to ~20s**
(`InvokeServer::SHUTDOWN_DRAIN_SECONDS`) for that run to tear down
cleanly and deliver its response. Terminating the child group is what
lets Chrome shut down gracefully instead of being SIGKILL'd out from
under an open profile — the child runs in its own process group, so
`tini` (even with `-g`) can't reach it; the server does.

Docker's default stop timeout is 10s, which is *shorter* than the drain
window — Docker would SIGKILL the container mid-drain. **Set `docker stop
-t` to at least 25s** (drain window + margin), or higher if your longest
workflow needs more time to unwind on SIGTERM:

```sh
docker stop -t 30 freentonic-server
```

A run that is mid-2FA (blocked on an operator prompt) will not finish
within the drain window; it is terminated and its `/invoke` returns an
error. Draining only rescues runs that can complete their teardown in
time — it is not a promise to let an arbitrarily long login finish.

---

## Step 7 — Upgrading

```sh
cd ~/code/freentonic
git pull
docker build -t freentonic:latest .
./docker-run-freentonic.sh stop
./docker-run-freentonic.sh server
```

The Chrome profile volume persists across container recreates, so
next-invoke login state is preserved.

If you are actively developing freentonic and don't want to rebuild
the image every time, mount `lib/` and `bin/` read-only:

```sh
docker run -d \
  --name freentonic-server \
  -p 127.0.0.1:7878:7878 \
  -v "$PWD/lib:/opt/freentonic/lib:ro" \
  -v "$PWD/bin:/opt/freentonic/bin:ro" \
  -v "$FREENTONIC_WORKFLOWS_DIR:/home/freentonic/workflows:ro" \
  -v "$FREENTONIC_RUNS_DIR:/workspace/runs" \
  -v "freentonic-chrome-profile:/home/freentonic/.cache/freentonic/chrome" \
  --shm-size=256m \
  -e "FREENTONIC_INVOKE_TOKEN=$FREENTONIC_INVOKE_TOKEN" \
  freentonic:latest
```

Restart the container after every change that touches `bin/freentonic-server`
or `lib/freentonic/invoke_*.rb`. Workflow YAML and ruby extractor/normalizer
changes are picked up automatically on the next invoke because the
subprocess re-loads them.

---

## Step 8 — Debugging with VNC

When `FREENTONIC_VNC=1` is set, the container starts **two** debug
surfaces pointing at the same Chrome session:

- **Raw VNC** on port **5900** — for a native VNC viewer.
- **noVNC** on port **6080** — an HTML+WebSocket client bundled in
  the image, so anyone with a browser can attach without installing a
  VNC app. `websockify` proxies `localhost:6080` → `localhost:5900`
  inside the container.

Both are gated on the single `FREENTONIC_VNC` toggle. There is no
separate sidecar container.

### Password: server mode

**There is no container-wide default password.** x11vnc's passwdfile
is rotated per-invoke from the `/invoke` request body:

1. The caller passes `"vnc_password": "<value>"` on `/invoke`.
2. The server writes that value to the passwdfile before spawning the
   child workflow.
3. x11vnc re-reads the passwdfile on every new VNC client connection,
   so the noVNC URL works immediately.
4. When the invoke ends, the server overwrites the passwdfile with a
   64-hex-char unreachable random value. Subsequent attach attempts
   fail until the next invoke rotates it.

An invoke with no `vnc_password` field has VNC effectively disabled
for that run — the server still writes a fresh unreachable random
value. This is intentional: an operator who forgot to set the
password shouldn't be able to attach.

See [`vnc_password` in the API doc](invoke-server-api.md#vnc-access-per-run)
for the field's charset and VNC's 8-byte truncation caveat.

### Password: cli mode

The legacy `./docker-run-freentonic.sh cli` path needs a static
password because there's no `/invoke` body to carry one. Two options:

- Set `FREENTONIC_VNC_PASSWORD=<value>` on the container start — the
  entrypoint uses that.
- Leave it unset — the entrypoint generates a random 12-char
  alphanumeric password and prints it once at startup:

```
[entrypoint]   Password: a7Qw2KxZ9NpT
```

Either way, noVNC and raw VNC both use the same per-container-start
value for the full lifetime of that `cli` container.

### Using the wrapper

```sh
FREENTONIC_VNC=1 ./docker-run-freentonic.sh server
```

This publishes 5900 and 6080 on `127.0.0.1`. The noVNC URL the
operator opens must include the password the web app passed on the
specific `/invoke` — the wrapper intentionally does not print a URL
with a password embedded, because there isn't one container-wide.

### Raw `docker run`

```sh
docker run -d \
  --name freentonic-server \
  -p 127.0.0.1:7878:7878 \
  -p 127.0.0.1:5900:5900 \
  -p 127.0.0.1:6080:6080 \
  -e FREENTONIC_VNC=1 \
  -e "FREENTONIC_INVOKE_TOKEN=$FREENTONIC_INVOKE_TOKEN" \
  -v "$FREENTONIC_WORKFLOWS_DIR:/home/freentonic/workflows:ro" \
  -v "$FREENTONIC_RUNS_DIR:/workspace/runs" \
  -v "freentonic-chrome-profile:/home/freentonic/.cache/freentonic/chrome" \
  --shm-size=256m \
  freentonic:latest
```

Native macOS client: `open vnc://localhost:5900`, then enter the
password the `/invoke` caller supplied.

### Security note

The noVNC HTML client carries the Chrome session of every tenant that
runs while you're watching — v1 is serialized, so you see them
sequentially. Keep `-p 127.0.0.1:6080:6080` on loopback only.

There is **no static password**. The server writes an unreachable
random password whenever no invoke is running, and rotates in the
per-invoke `vnc_password` (from the `/invoke` request) only for the
duration of that run, relocking on exit. So VNC is attachable only
while a run you launched with a `vnc_password` is in flight, using that
value. VNC's DES-based auth truncates the password to its first 8
chars, so treat `vnc_password` as a low-entropy debug secret, not real
access control. If you need to attach from another machine, tunnel
through SSH (`ssh -L 6080:127.0.0.1:6080 host`) rather than publishing
to a non-loopback interface.

Because v1 is serialized, you only ever see one workflow at a time —
which is also what makes VNC debugging tractable.

---

## Step 9 — Inspecting and pruning Chrome profiles

Chrome profiles live in the `freentonic-chrome-profile` named volume,
one subdirectory per `profile_key`. Over time — as tenants come and
go, credentials rotate, or workflows are retired — you'll want to see
what's in there and remove stale entries.

### List all profiles

Works whether the server is running or not; spins up a throwaway
container that read-mounts the volume:

```sh
docker run --rm -v freentonic-chrome-profile:/profiles:ro alpine \
  sh -c 'cd /profiles && du -sh */ 2>/dev/null | sort -rh'
```

Typical output:

```
28M	ing__owner42/
24M	revolut__owner42/
19M	ing__owner99/
2.1M	acme__demo/
```

The first column is the profile's on-disk size, the second is the
`profile_key` (directory name) your web app passes on `/invoke`.

If the server is running, `docker exec` works too:

```sh
docker exec freentonic-server \
  sh -c 'cd /home/freentonic/.cache/freentonic/chrome && du -sh */ | sort -rh'
```

### Remove a single profile by name

**Preferred** — via the `/profiles/prune` HTTP endpoint. It acquires
the invoke mutex so it can't race an in-flight Chrome session:

```sh
curl -sS -X POST \
  -H "Authorization: Bearer $FREENTONIC_INVOKE_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"profile_key":"ing__owner42"}' \
  http://127.0.0.1:7878/profiles/prune
# {"deleted":["ing__owner42"],"count":1}
```

See [invoke-server-api.md](invoke-server-api.md#post-profilesprune) for
the prefix form (bulk delete by prefix) and full error semantics.

**Escape hatch** — when the server isn't running or you need raw
filesystem access:

```sh
docker run --rm -v freentonic-chrome-profile:/profiles alpine \
  rm -rf /profiles/ing__owner42
```

Don't use the escape hatch while the server is running: Chrome may be
holding the profile open, and blowing it out from under a live session
corrupts the remaining state. Use the API.

---

## Step 10 — Cleanup

```sh
./docker-run-freentonic.sh stop
docker volume rm freentonic-chrome-profile   # wipes ALL saved logins
docker rmi freentonic:latest
```

Removing the profile volume forces every subsequent invoke to do a
full login + captcha on the bank. Don't do this unless you actually
want that reset.

---

## Security notes

- **The bearer token is the only access control.** Treat it like a
  password. Rotate by stopping the container and starting with a new
  token (invokes in flight during rotation are unaffected).
- **`-p 127.0.0.1:7878:7878`** is critical. Binding to `0.0.0.0` on
  the host would let anyone on the network try tokens against your
  server. If you must expose it across hosts, terminate TLS + auth
  upstream.
- **Workflows are trusted code.** The server does not sandbox the
  Ruby extractor/normalizer code in a workflow. Audit anything you
  bind-mount into `/home/freentonic/workflows`.
- **Chrome profiles are keyed by `profile_key`.** If two tenants use
  the same `profile_key` with different credentials, their sessions
  can conflict. Always derive a per-tenant `profile_key` (e.g.
  `acme__tenant42`) in your web app.
- **Inline credentials are passed via an inherited pipe**, not a
  file. The child reads them from fd 3 (the `inline_fd` secret
  backend) and the bytes never reach a filesystem path. Because
  invokes are serialized and the pipe is anonymous, two runs'
  credentials never coexist on disk.

---

## Troubleshooting

**"workflows directory is empty"**
The bind mount didn't land. Check that `FREENTONIC_WORKFLOWS_DIR`
points at a directory with files in it, and that Docker Desktop's
File Sharing list includes the parent path. On macOS, paths under
`/tmp` are not shared by default — use a path under your home dir,
or add `/tmp` in Docker Desktop → Settings → Resources → File Sharing.

**`curl: (52) Empty reply from server`**
Your server is bound to `127.0.0.1` inside the container, which
Docker's port forwarding can't reach. Make sure `FREENTONIC_LISTEN_ADDR`
is unset or `0.0.0.0`. The container entrypoint sets it to `0.0.0.0`
by default — don't override it with `-e FREENTONIC_LISTEN_ADDR=127.0.0.1`
unless you know why.

**"no exporters configured — pass --export NAME"**
Your `/invoke` request is missing the `export` block. Add it, or include
`"dump_raw"` / `"dump_normalized"` in a future version (not currently
supported via the HTTP API — use the `cli` subcommand for ad-hoc dumps).

**`exit_code` is 2 for every invoke**
The http exporter is failing (usually 401 from your receiver, or a
connection refusal). Inspect `runs/<run_id>/log` — the exporter's error
message is printed on the last line.

**401 from your own receiver but not from the http exporter directly**
Make sure `export.token` is being sent on the `/invoke` body. The
server injects it into the child's env as `FREENTONIC_HTTP_TOKEN`;
the http exporter at `lib/freentonic/exporters/http.rb` reads from
there. If the receiver rejects, check the token value before you
suspect freentonic.

**Chrome reports "SingletonLock" on start**
A prior Chrome crash left a stale lock in the profile directory.
`lib/freentonic/chrome_cdp.rb:120–125` already removes these on
launch, but if you see it anyway, `docker exec freentonic-server rm
-f /home/freentonic/.cache/freentonic/chrome/<profile_key>/Singleton*`
and retry.
