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
- Passes credentials through an in-memory tmpfs and the API token
  through a child-only environment variable — neither touches disk
  (other than the tmpfs) and neither appears in `ps` output or argv.

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

All optional except `FREENTONIC_INVOKE_TOKEN` (strongly recommended;
the server logs a warning if missing).

| Variable | Default | Purpose |
|---|---|---|
| `FREENTONIC_INVOKE_TOKEN` | *(none — unauthenticated)* | Bearer token required on `/invoke`, `/status`, `/cancel/:id`. Missing → server runs in OPEN mode (for local dev only). |
| `FREENTONIC_LISTEN_ADDR` | `0.0.0.0` inside the container | Interface to bind. Override to `127.0.0.1` only if you're running freentonic outside a container. |
| `FREENTONIC_LISTEN_PORT` | `7878` | Port inside the container. |
| `FREENTONIC_WORKFLOWS_DIR` | `/home/freentonic/workflows` | Workflow root inside the container. The `/invoke` request's `workflow` field is resolved against this path. |
| `FREENTONIC_RUNS_DIR` | `/workspace/runs` | Per-run artifact root inside the container. |
| `FREENTONIC_TMPFS_DIR` | `/dev/shm/freentonic/runs` | Where inline credentials are written during a run (auto-cleaned). |
| `FREENTONIC_CHROME_PROFILE_ROOT` | `/home/freentonic/.cache/freentonic/chrome` | Chrome profile parent. Subdirectories are created per `profile_key`. |
| `FREENTONIC_VNC` | `1` | Starts x11vnc on `:5900` for debugging. Password: `freentonic`. The wrapper publishes `-p 127.0.0.1:5900:5900` whenever this is `1`. Set to `0` to skip VNC entirely. |

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

**Graceful shutdown**: `docker stop` sends SIGTERM. The server stops
accepting new invokes (responds `503 Service Unavailable` to any new
`/invoke` during the grace period) and waits for the in-flight invoke
to finish. Docker's default stop timeout is 10s; if an in-flight
invoke takes longer, Docker sends SIGKILL. Increase with `docker stop
-t 60 freentonic-server` if your longest workflow is expected to
exceed 10s during shutdown.

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

Set `FREENTONIC_VNC=1` and publish port 5900:

```sh
docker run -d \
  --name freentonic-server \
  -p 127.0.0.1:7878:7878 \
  -p 127.0.0.1:5900:5900 \
  -e FREENTONIC_VNC=1 \
  -e "FREENTONIC_INVOKE_TOKEN=$FREENTONIC_INVOKE_TOKEN" \
  -v "$FREENTONIC_WORKFLOWS_DIR:/home/freentonic/workflows:ro" \
  -v "$FREENTONIC_RUNS_DIR:/workspace/runs" \
  -v "freentonic-chrome-profile:/home/freentonic/.cache/freentonic/chrome" \
  --shm-size=256m \
  freentonic:latest
```

On macOS: `open vnc://localhost:5900`, password `freentonic`.
You see the live Chrome window during each invoke.

Because v1 is serialized, you only ever see one workflow at a time —
which is also what makes VNC debugging tractable.

---

## Step 9 — Cleanup

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
- **The tmpfs secrets file at `/dev/shm/freentonic/runs/<run_id>/secrets.env`**
  lives only for the duration of the invoke and has mode `0600`.
  Because invokes are serialized, two runs' secrets files never coexist.

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
