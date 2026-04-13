# Running in Docker

This guide covers running freentonic inside Docker. Docker provides a
self-contained environment with Chrome and Ruby pre-installed, so you
don't need to set up anything on your host machine. It also isolates
Chrome from your host browser — no shared profiles, no risk of
interfering with your normal browsing.

## Prerequisites

- **Docker** — install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
  (macOS/Windows) or Docker Engine (Linux)
- That's it. No Ruby, no Chrome, no gems to install.

## Step 1: Build the image

Clone freentonic and build the Docker image:

```sh
git clone https://github.com/GermanDZ/freentonic
cd freentonic
docker build -t freentonic .
```

The image is based on `ruby:3.2-slim` with Chromium, and weighs
roughly 500 MB. It includes a virtual display (Xvfb) so Chrome runs
in non-headless mode — this avoids issues with behavioral captchas
that some banking sites use to block headless browsers.

## Step 2: Run your first workflow

The simplest way to run freentonic in Docker is with the included
wrapper script. It handles volume mounts and container flags for you.

### Using providers from GitHub

On first startup, the container clones
[freentonic-providers](https://github.com/GermanDZ/freentonic-providers)
automatically. Run a workflow like this:

```sh
./docker-run-freentonic.sh \
  --workflow /home/freentonic/providers/freentonic-providers/ing/workflow.yml \
  --secrets cli \
  --export csv --export-path /workspace/movements.csv \
  --export-csv-select accounts.movements
```

A few things to note:

- `--secrets cli` prompts you for credentials interactively.
  On the first run, you'll type your login details. They are not saved
  between container runs unless you use a secrets file (see below).
- `--export-path /workspace/...` writes inside the container's
  `/workspace` directory, which is mounted to your **current directory**
  on the host. So `movements.csv` will appear in whatever folder you
  ran the command from.
- Providers are cached in a Docker volume (`freentonic-providers`), so
  subsequent runs won't re-clone — just a fast `git pull`.

### Using local provider workflows

If you're developing a provider locally or have a private providers
repo, mount it directly instead:

```sh
FREENTONIC_SKIP_PROVIDERS=1 docker run --rm -it \
  -v "$(pwd):/workspace" \
  -v "/path/to/your/freentonic-providers:/home/freentonic/providers/freentonic-providers:ro" \
  -v "freentonic-chrome-profile:/home/freentonic/.cache/freentonic/chrome" \
  --shm-size=256m \
  freentonic \
  --workflow /home/freentonic/providers/freentonic-providers/ing/workflow.yml \
  --secrets cli \
  --export json --export-path /workspace/out.json
```

`FREENTONIC_SKIP_PROVIDERS=1` tells the entrypoint to skip cloning
from GitHub. The `-v` flag mounts your local directory read-only (`:ro`)
into the container at the same path the entrypoint would clone to.

## Secrets

Freentonic needs your login credentials to access your bank. Inside
Docker, there are two ways to provide them.

### Interactive prompts (simple, no persistence)

Use `--secrets cli` and the container will prompt you each time:

```sh
./docker-run-freentonic.sh \
  --workflow /home/freentonic/providers/freentonic-providers/ing/workflow.yml \
  --secrets cli \
  --export json --export-path /workspace/out.json
```

This is the simplest option. Credentials are only held in memory for
the duration of the run.

### Secrets file (persistent, no prompts)

Create a plain-text file on your host with one `KEY=VALUE` per line.
The key format is `<provider_key>.<secret_name>`:

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

The `chmod 600` is required — freentonic refuses to read a secrets
file that is readable by other users.

Then pass it via the `FREENTONIC_SECRETS_FILE` environment variable:

```sh
FREENTONIC_SECRETS_FILE=~/.freentonic-secrets ./docker-run-freentonic.sh \
  --workflow /home/freentonic/providers/freentonic-providers/ing/workflow.yml \
  --export csv --export-path /workspace/movements.csv \
  --export-csv-select accounts.movements
```

The wrapper mounts the file into the container and automatically adds
`--secrets plain_file --secrets-file ...` — you don't need to pass
those flags yourself.

## Chrome profile persistence

Login state (cookies, device trust) is persisted in a Docker volume
called `freentonic-chrome-profile`. This means:

- The first run does a full login (credentials, captcha, 2FA if needed).
- Subsequent runs may skip the full login if the site remembers your
  session, only asking for a PIN.

To start fresh (clear all saved browser state):

```sh
docker volume rm freentonic-chrome-profile
```

## Debugging with VNC

Sometimes you need to see what Chrome is doing — a captcha to solve,
a login flow to inspect, or an error to diagnose. Enable VNC mode:

```sh
FREENTONIC_VNC=1 ./docker-run-freentonic.sh \
  --workflow /home/freentonic/providers/freentonic-providers/ing/workflow.yml \
  --secrets cli \
  --export json --export-path /workspace/out.json
```

The container will print connection instructions:

```
[entrypoint] VNC server ready. Connect with:
[entrypoint]   macOS:  open vnc://localhost:5900
[entrypoint]   Linux:  vncviewer localhost:5900
[entrypoint]   Password: freentonic
```

On macOS, run `open vnc://localhost:5900` in another terminal. This
opens the built-in Screen Sharing app. Enter `freentonic` as the
password. You'll see the Chrome window inside the container and can
watch the login flow in real time.

## Output files

All `--export-path` paths should use `/workspace/` as the prefix. This
directory is mounted to your current working directory on the host:

```sh
# Inside the container:  /workspace/data.json
# On your host:          ./data.json

--export json --export-path /workspace/data.json
--export csv  --export-path /workspace/movements.csv
```

Timeout screenshots are also saved to `/workspace/` so they appear in
your local directory.

## Environment variables reference

| Variable | Default | Description |
|----------|---------|-------------|
| `FREENTONIC_SECRETS_FILE` | *(none)* | Host path to a secrets file. Auto-mounted and wired up. |
| `FREENTONIC_VNC` | `0` | Set to `1` to enable VNC server on port 5900. |
| `FREENTONIC_SKIP_PROVIDERS` | `0` | Set to `1` to skip cloning/updating providers from GitHub. |
| `FREENTONIC_PROVIDERS_REPO` | GitHub URL | Override the providers git repo URL. |
| `FREENTONIC_PROVIDERS_REF` | `main` | Pin providers to a specific branch, tag, or commit. |
| `FREENTONIC_IMAGE` | `freentonic:latest` | Docker image name (for the wrapper script). |
| `FREENTONIC_PROVIDERS_VOLUME` | `freentonic-providers` | Named volume for cached providers. |
| `FREENTONIC_CHROME_PROFILE_VOLUME` | `freentonic-chrome-profile` | Named volume for Chrome profile persistence. |

## Running without the wrapper script

The wrapper script (`docker-run-freentonic.sh`) is a convenience — it
sets up volume mounts and passes environment variables. You can always
run `docker run` directly:

```sh
docker run --rm -it \
  -e FREENTONIC_SKIP_PROVIDERS=1 \
  -v "$(pwd):/workspace" \
  -v "/path/to/providers:/home/freentonic/providers/freentonic-providers:ro" \
  -v "freentonic-chrome-profile:/home/freentonic/.cache/freentonic/chrome" \
  --shm-size=256m \
  freentonic \
  --workflow /home/freentonic/providers/freentonic-providers/ing/workflow.yml \
  --secrets cli \
  --export json --export-path /workspace/out.json
```

Key flags to remember:

- `-v "$(pwd):/workspace"` — mount current directory for output files
- `-v "...chrome-profile:/home/freentonic/.cache/freentonic/chrome"` — persist login state
- `--shm-size=256m` — Chrome needs more shared memory than Docker's 64 MB default
- `-e FREENTONIC_SKIP_PROVIDERS=1` — when mounting local providers
- `-p 5900:5900 -e FREENTONIC_VNC=1` — when you need VNC

## Cleaning up

```sh
# Remove all Docker volumes (providers cache + Chrome profile):
docker volume rm freentonic-providers freentonic-chrome-profile

# Remove the Docker image:
docker rmi freentonic
```
