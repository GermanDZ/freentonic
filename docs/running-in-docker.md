# Running in Docker (single-shot CLI mode)

> **New as of the invoke-server refactor:** the default container mode is
> now a long-running HTTP server. For that (the recommended path for
> automation), see:
>
> - [invoke-server-deployment.md](invoke-server-deployment.md) — how to deploy and run the server.
> - [invoke-server-api.md](invoke-server-api.md) — the HTTP API reference.
>
> This page documents the **legacy single-shot CLI mode**, kept as a
> back-compat escape hatch for one-off local runs — useful when
> developing a new provider, capturing a fresh login interactively, or
> running a quick export without standing up the server.

In single-shot mode, each run spins up a fresh container that executes
one workflow and exits. All flags after `./docker-run-freentonic.sh cli`
are passed straight to `bin/freentonic` inside the container.

---

## Prerequisites

- **Docker Desktop** (macOS/Windows) or Docker Engine (Linux).
- A workflows directory on your host (e.g. the `freentonic-providers`
  repo cloned locally).

## Step 1 — Build the image

```sh
git clone https://github.com/GermanDZ/freentonic
cd freentonic
docker build -t freentonic:latest .
```

The image whitelists one runtime gem, **tzinfo** (+ tzinfo-data), so
workflows can book dates in a named IANA timezone (e.g.
`output_timezone: Europe/Madrid`). Pass `--build-arg INCLUDE_TZINFO=0` for
a strictly stdlib image — named-zone workflows then fail with a clear
error at normalize time; UTC / fixed-offset workflows are unaffected.

## Step 2 — Run a workflow once

```sh
git clone https://github.com/GermanDZ/freentonic-providers ~/freentonic/workflows

export FREENTONIC_WORKFLOWS_DIR=~/freentonic/workflows
./docker-run-freentonic.sh cli \
  --workflow /home/freentonic/workflows/ing/workflow.yml \
  --secrets cli \
  --export csv --export-path /workspace/movements.csv \
  --export-csv-select accounts.movements
```

Notes:

- Workflows are **bind-mounted read-only** from the host into
  `/home/freentonic/workflows`. There's no more "git clone on startup"
  behavior — if you want the `freentonic-providers` repo, clone it to
  your host and point `FREENTONIC_WORKFLOWS_DIR` at it.
- `--secrets cli` prompts you for credentials in the terminal. They
  are only held in memory for the run.
- `--export-path /workspace/...` writes inside the container's
  `/workspace`, which the wrapper mounts to your **current directory**
  on the host. So `movements.csv` appears in whatever folder you ran
  the command from.

## Secrets

### Interactive prompts

```sh
./docker-run-freentonic.sh cli \
  --workflow /home/freentonic/workflows/ing/workflow.yml \
  --secrets cli \
  --export json --export-path /workspace/out.json
```

### Secrets file

Create a plain-text file on your host with one `KEY=VALUE` per line,
keys scoped as `<provider_key>.<secret_name>`:

```sh
cat > ~/.freentonic-secrets << 'EOF'
ing.USER_DNI=12345678A
ing.USER_BIRTHDAY_DD=01
ing.USER_BIRTHDAY_MM=06
ing.USER_BIRTHDAY_YYYY=1990
ing.USER_PIN=123456
EOF
chmod 600 ~/.freentonic-secrets
```

The `chmod 600` is mandatory — freentonic refuses to read a more
permissive secrets file.

Pass the file via `FREENTONIC_SECRETS_FILE`; the wrapper mounts the
parent directory read-only into the container and prints the exact
`--secrets plain_file --secrets-file ...` flags to append:

```sh
FREENTONIC_SECRETS_FILE=~/.freentonic-secrets ./docker-run-freentonic.sh cli \
  --workflow /home/freentonic/workflows/ing/workflow.yml \
  --secrets plain_file --secrets-file /home/freentonic/.secrets/.freentonic-secrets \
  --export csv --export-path /workspace/movements.csv \
  --export-csv-select accounts.movements
```

In server mode you don't need any of this — the web app sends
credentials on the `/invoke` body and the server hands them to the
child process through an inherited pipe.

## Chrome profile persistence

The named volume `freentonic-chrome-profile` is shared between the
`cli` subcommand and the invoke server. Cookies, 2FA device trust,
and session state persist across runs. Reset with:

```sh
docker volume rm freentonic-chrome-profile
```

## Debugging with VNC

Enable VNC and publish ports 5900 (raw VNC) + 6080 (noVNC browser client):

```sh
FREENTONIC_VNC=1 FREENTONIC_VNC_PASSWORD=choose-your-own \
  ./docker-run-freentonic.sh cli \
  --workflow /home/freentonic/workflows/ing/workflow.yml \
  --secrets cli \
  --export json --export-path /workspace/out.json
```

The `FREENTONIC_VNC_PASSWORD` you set is what x11vnc uses for the
container's lifetime. Leave it unset and the entrypoint generates a
random 12-char password and prints it once — grep the container logs
for `[entrypoint]   Password:`.

Two ways to attach:

- Browser (no client install): `http://localhost:6080/vnc.html?host=localhost&port=6080&password=<yours>&autoconnect=true`
- Native macOS client: `open vnc://localhost:5900`, then enter the password.

VNC's wire auth truncates to 8 bytes — pick a password with real
entropy in those first 8 chars.

## Running without the wrapper

```sh
docker run --rm -it \
  -v "$(pwd):/workspace" \
  -v "$HOME/freentonic/workflows:/home/freentonic/workflows:ro" \
  -v "freentonic-chrome-profile:/home/freentonic/.cache/freentonic/chrome" \
  --shm-size=256m \
  freentonic:latest \
  cli \
    --workflow /home/freentonic/workflows/ing/workflow.yml \
    --secrets cli \
    --export json --export-path /workspace/out.json
```

The literal `cli` after the image name tells the entrypoint to bypass
`freentonic-server` and exec `bin/freentonic` directly.

## Cleanup

```sh
docker volume rm freentonic-chrome-profile
docker rmi freentonic:latest
```
