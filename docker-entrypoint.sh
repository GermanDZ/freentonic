#!/bin/bash
set -euo pipefail

# Container runs as a single user (`freentonic`), so any file we create
# should be owner-only. This tightens defaults for every child process
# (Xvfb, x11vnc, novnc_proxy, the ruby freentonic subprocess, and Chrome)
# so per-run artifacts — logs, screenshots, dumped payloads — don't end up
# group- or world-readable on a bind-mounted host directory.
umask 0077

# x11vnc passwdfile. The `read:` prefix in x11vnc-speak means "re-read
# the file on every new client connection" (NOT "read once" — counter-
# intuitive given the name). That's exactly what per-invoke password
# rotation requires. Don't use `rdfile:` — it isn't a recognised prefix
# and x11vnc tries to open a file literally named `rdfile:/...`.
# Server mode: InvokeRunner rotates it per-invoke from the /invoke body.
# cli mode: seeded at startup (env or random) and then static for the run.
VNC_PASSWORD_FILE="${FREENTONIC_VNC_PASSWORD_FILE:-/dev/shm/freentonic/vnc-password}"

# Seed the passwdfile. Echoes the chosen password on stdout so callers can
# decide whether to show it to the operator (cli mode) or keep it hidden
# (server mode, where the real password comes from the /invoke body).
init_vnc_passwdfile() {
  local mode="$1"   # "cli" or "server"
  local pw
  if [ "$mode" = "cli" ] && [ -n "${FREENTONIC_VNC_PASSWORD:-}" ]; then
    pw="$FREENTONIC_VNC_PASSWORD"
  elif [ "$mode" = "cli" ]; then
    # Generate a 12-char alphanumeric password so the operator can copy-paste
    # it out of the container logs.
    pw="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)"
  else
    # Server mode: seed with a 64-hex-char unreachable value. InvokeRunner
    # overwrites this before each invoke and in its ensure block, so attach
    # attempts between invokes always hit the unreachable sentinel.
    pw="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  mkdir -p "$(dirname "$VNC_PASSWORD_FILE")"
  # umask 0077 above + chmod belt-and-suspenders so other local processes
  # can't read the file even if they share the image layer somehow.
  printf '%s' "$pw" > "$VNC_PASSWORD_FILE"
  chmod 0600 "$VNC_PASSWORD_FILE"
  printf '%s' "$pw"
}

# Start x11vnc + noVNC if FREENTONIC_VNC=1. Shared by both the default
# server path and the `cli` escape hatch.
start_vnc_stack_if_enabled() {
  local mode="${1:-server}"
  if [ "${FREENTONIC_VNC:-0}" != "1" ]; then
    return 0
  fi
  local pw
  pw="$(init_vnc_passwdfile "$mode")"
  x11vnc -display :99 -forever -passwdfile "read:${VNC_PASSWORD_FILE}" -quiet &
  sleep 0.3
  # noVNC wrapper launches websockify + serves the HTML client. Background
  # it and let its stdout/stderr land in the container logs; useful for
  # diagnosing the rare port-in-use / python-missing problem.
  /opt/novnc/utils/novnc_proxy \
    --vnc localhost:5900 \
    --listen 6080 \
    --web /opt/novnc &
  sleep 0.3
  echo "[entrypoint] VNC ready. Connect with:"
  echo "[entrypoint]   Browser:  http://localhost:6080/vnc.html?host=localhost&port=6080&autoconnect=true"
  echo "[entrypoint]   Raw VNC:  vnc://localhost:5900"
  if [ "$mode" = "cli" ]; then
    echo "[entrypoint]   Password: ${pw}"
  else
    echo "[entrypoint]   Password: per-invoke — send { \"vnc_password\": ... } on /invoke"
    echo "[entrypoint]             (server seeds an unreachable value until the first invoke rotates it)"
  fi
}

# Backward-compat escape hatch: `docker run freentonic:latest cli --workflow ...`
# runs the single-shot CLI exactly like before the server refactor. Handy for
# local debugging; the default mode is the long-running invoke server.
if [ "${1:-}" = "cli" ]; then
  shift
  # Xvfb is still needed for the CLI's Chrome.
  Xvfb :99 -screen 0 1920x1080x24 &>/dev/null &
  export DISPLAY=:99
  sleep 0.3
  start_vnc_stack_if_enabled cli
  exec ruby -I/opt/freentonic/lib /opt/freentonic/bin/freentonic --no-sandbox "$@"
fi

# Warn if the workflows directory is empty — the first /invoke will 404
# until the operator mounts their YAMLs. Not fatal so the server can still
# answer /healthz while things are being set up.
WORKFLOWS_DIR="${FREENTONIC_WORKFLOWS_DIR:-/home/freentonic/workflows}"
if [ ! -d "${WORKFLOWS_DIR}" ] || [ -z "$(ls -A "${WORKFLOWS_DIR}" 2>/dev/null)" ]; then
  echo "[entrypoint] Warning: workflows directory ${WORKFLOWS_DIR} is empty."
  echo "[entrypoint] Bind-mount your workflow YAMLs here, e.g."
  echo "[entrypoint]   -v /path/to/workflows:${WORKFLOWS_DIR}:ro"
fi

# Tmpfs dir for per-invoke secret files. /dev/shm is a container-local
# tmpfs so it never hits the backing filesystem and evaporates on restart.
TMPFS_DIR="${FREENTONIC_TMPFS_DIR:-/dev/shm/freentonic/runs}"
mkdir -p "${TMPFS_DIR}"
chmod 0700 "${TMPFS_DIR}"

# Always use Xvfb virtual display — gives Chrome a real display context so
# behavioral captchas don't reject it. Lightweight (~8MB RAM).
Xvfb :99 -screen 0 1920x1080x24 &>/dev/null &
export DISPLAY=:99
sleep 0.3

start_vnc_stack_if_enabled server

# Inside a container, binding to 127.0.0.1 would be unreachable from the host.
# Docker's port forwarding (e.g. -p 127.0.0.1:7878:7878) requires the server
# to accept connections on 0.0.0.0 inside its network namespace. The host-side
# bind in `-p` already limits exposure, so this doesn't widen the attack surface.
export FREENTONIC_LISTEN_ADDR="${FREENTONIC_LISTEN_ADDR:-0.0.0.0}"

exec /opt/freentonic/bin/freentonic-server "$@"
