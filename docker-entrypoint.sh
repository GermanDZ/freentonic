#!/bin/bash
set -euo pipefail

# Start x11vnc + noVNC if FREENTONIC_VNC=1. Shared by both the default
# server path and the `cli` escape hatch.
start_vnc_stack_if_enabled() {
  if [ "${FREENTONIC_VNC:-0}" != "1" ]; then
    return 0
  fi
  x11vnc -display :99 -forever -passwd freentonic -quiet &
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
  echo "[entrypoint]   Browser:   http://localhost:6080/vnc.html?host=localhost&port=6080&password=freentonic&autoconnect=true"
  echo "[entrypoint]   Raw VNC:   vnc://localhost:5900"
  echo "[entrypoint]   Password:  freentonic"
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
  start_vnc_stack_if_enabled
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

start_vnc_stack_if_enabled

# Inside a container, binding to 127.0.0.1 would be unreachable from the host.
# Docker's port forwarding (e.g. -p 127.0.0.1:7878:7878) requires the server
# to accept connections on 0.0.0.0 inside its network namespace. The host-side
# bind in `-p` already limits exposure, so this doesn't widen the attack surface.
export FREENTONIC_LISTEN_ADDR="${FREENTONIC_LISTEN_ADDR:-0.0.0.0}"

exec /opt/freentonic/bin/freentonic-server "$@"
