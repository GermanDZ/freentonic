#!/bin/bash
# Freentonic container helper.
#
# Subcommands:
#   server              Start the long-running invoke server in the background.
#   stop                Stop and remove the running container.
#   logs                Follow container logs.
#   invoke REQ_JSON     POST /invoke with the JSON file at REQ_JSON.
#   cli ARGS...         One-shot CLI run (legacy path, no server).
#
# Env vars:
#   FREENTONIC_IMAGE           image tag (default freentonic:latest)
#   FREENTONIC_WORKFLOWS_DIR   host path to mount at /home/freentonic/workflows (REQUIRED for server)
#   FREENTONIC_RUNS_DIR        host path to mount at /workspace/runs (default: $(pwd)/freentonic-runs)
#   FREENTONIC_INVOKE_TOKEN    bearer token for /invoke (REQUIRED for server
#                              unless FREENTONIC_INVOKE_TOKEN_FILE is set;
#                              passed via -e, so visible in `docker inspect`)
#   FREENTONIC_INVOKE_TOKEN_FILE  host path to a file of bearer tokens (one per
#                              line). Mounted read-only; keeps the secret out
#                              of `docker inspect`. Multiple lines = a token
#                              set for zero-downtime rotation. Takes precedence
#                              over FREENTONIC_INVOKE_TOKEN.
#   FREENTONIC_LISTEN_PORT     host port to expose the invoke server on (default 7878)
#   FREENTONIC_CONTAINER_NAME  container name (default freentonic-server)
#   FREENTONIC_VNC             0|1 (default 1) — expose VNC on 5900 for debug. Set to 0 to skip.
#   FREENTONIC_CHROME_PROFILE_VOLUME  Docker volume name for the Chrome profile root
#                                     (default freentonic-chrome-profile)

set -euo pipefail

IMAGE_NAME="${FREENTONIC_IMAGE:-freentonic:latest}"
CONTAINER_NAME="${FREENTONIC_CONTAINER_NAME:-freentonic-server}"
CHROME_PROFILE_VOLUME="${FREENTONIC_CHROME_PROFILE_VOLUME:-freentonic-chrome-profile}"
LISTEN_PORT="${FREENTONIC_LISTEN_PORT:-7878}"
VNC="${FREENTONIC_VNC:-1}"

require_env() {
  local name="$1"
  local purpose="$2"
  if [ -z "${!name:-}" ]; then
    echo "error: $name is required ($purpose)" >&2
    exit 2
  fi
}

cmd_server() {
  require_env FREENTONIC_WORKFLOWS_DIR "host path to workflows YAMLs"

  local workflows_dir runs_dir
  workflows_dir="$(cd "${FREENTONIC_WORKFLOWS_DIR}" && pwd)"
  runs_dir="${FREENTONIC_RUNS_DIR:-$(pwd)/freentonic-runs}"
  mkdir -p "${runs_dir}"
  runs_dir="$(cd "${runs_dir}" && pwd)"

  local args=(
    docker run -d
    --name "${CONTAINER_NAME}"
    --restart unless-stopped
    -p "127.0.0.1:${LISTEN_PORT}:7878"
    -v "${workflows_dir}:/home/freentonic/workflows:ro"
    -v "${runs_dir}:/workspace/runs"
    -v "${CHROME_PROFILE_VOLUME}:/home/freentonic/.cache/freentonic/chrome"
    --shm-size=256m
    # ── Hardening ────────────────────────────────────────────────────────
    # Drop every Linux capability and forbid privilege escalation: Chrome
    # runs --no-sandbox unconditionally, so a compromised renderer already
    # shares the freentonic uid — deny it any path to more.
    --cap-drop ALL
    --security-opt no-new-privileges
    # Read-only root filesystem. Everything the process legitimately writes
    # is a named volume (runs, chrome profile) or a tmpfs below. This turns
    # the rest of the image immutable, so a renderer compromise can't drop a
    # persistent implant on the rootfs. The tmpfs list is the minimum that
    # keeps Chrome + Xvfb happy under --read-only, verified against the
    # ING anti-detection flag set:
    #   /tmp                       Xvfb sockets, Chrome scratch
    #   ~/.config ~/.local ~/.pki  Chrome config / crashpad DB / NSS cert DB
    #   /dev/shm                   supplied writable by --shm-size above
    --read-only
    --tmpfs /tmp
    --tmpfs /home/freentonic/.config
    --tmpfs /home/freentonic/.local
    --tmpfs /home/freentonic/.pki
  )

  # Token delivery. Prefer a mounted file (FREENTONIC_INVOKE_TOKEN_FILE, a
  # host path): only the in-container path lands in `docker inspect`, never
  # the secret. Fall back to -e for the single-token convenience case, with
  # a note that the value is then visible to anyone who can inspect the
  # container. Either way the server accepts a *set* of tokens, so the file
  # can hold old+new during a rotation window.
  if [ -n "${FREENTONIC_INVOKE_TOKEN_FILE:-}" ]; then
    local token_file
    token_file="$(cd "$(dirname "${FREENTONIC_INVOKE_TOKEN_FILE}")" && pwd)/$(basename "${FREENTONIC_INVOKE_TOKEN_FILE}")"
    if [ ! -f "${token_file}" ]; then
      echo "error: FREENTONIC_INVOKE_TOKEN_FILE=${token_file} not found" >&2
      exit 2
    fi
    args+=(
      -v "${token_file}:/run/freentonic/invoke-token:ro"
      -e "FREENTONIC_INVOKE_TOKEN_FILE=/run/freentonic/invoke-token"
    )
  else
    require_env FREENTONIC_INVOKE_TOKEN "bearer token protecting /invoke (or set FREENTONIC_INVOKE_TOKEN_FILE to a host token file to keep it out of \`docker inspect\`)"
    echo "note: passing the token via -e; it is visible in \`docker inspect\`. Set FREENTONIC_INVOKE_TOKEN_FILE to a host file to avoid that." >&2
    args+=(-e "FREENTONIC_INVOKE_TOKEN=${FREENTONIC_INVOKE_TOKEN}")
  fi

  if [ "${VNC}" = "1" ]; then
    args+=(
      -p "127.0.0.1:5900:5900"
      -p "127.0.0.1:6080:6080"
      -e "FREENTONIC_VNC=1"
    )
  fi

  args+=("${IMAGE_NAME}")

  echo "starting ${CONTAINER_NAME} (workflows=${workflows_dir}, runs=${runs_dir})"
  "${args[@]}"
  echo "listening on http://127.0.0.1:${LISTEN_PORT}"
  if [ "${VNC}" = "1" ]; then
    echo "noVNC at http://127.0.0.1:6080/vnc.html?host=localhost&port=6080 (enter the vnc_password from your /invoke request; VNC is locked when no run is in flight — there is no static password)"
  fi
}

cmd_stop() {
  docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  docker rm   "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  echo "stopped ${CONTAINER_NAME}"
}

cmd_logs() {
  exec docker logs -f "${CONTAINER_NAME}" "$@"
}

cmd_invoke() {
  require_env FREENTONIC_INVOKE_TOKEN "bearer token for /invoke"
  local payload="${1:-}"
  if [ -z "${payload}" ] || [ ! -f "${payload}" ]; then
    echo "usage: $0 invoke PATH_TO_REQUEST_JSON" >&2
    exit 2
  fi
  curl -sS --fail-with-body \
    -H "Authorization: Bearer ${FREENTONIC_INVOKE_TOKEN}" \
    -H "Content-Type: application/json" \
    --data @"${payload}" \
    "http://127.0.0.1:${LISTEN_PORT}/invoke"
  echo
}

cmd_cli() {
  # Legacy single-shot path. Runs a throwaway container that exits when the
  # workflow finishes. The container's entrypoint special-cases the `cli`
  # first argument and execs the old code path.
  require_env FREENTONIC_WORKFLOWS_DIR "host path to workflows YAMLs"
  local workflows_dir
  workflows_dir="$(cd "${FREENTONIC_WORKFLOWS_DIR}" && pwd)"

  local tty_flag=""
  if [ -t 0 ]; then tty_flag="-t"; fi

  local args=(
    docker run --rm -i ${tty_flag}
    -v "$(pwd):/workspace"
    -v "${workflows_dir}:/home/freentonic/workflows:ro"
    -v "${CHROME_PROFILE_VOLUME}:/home/freentonic/.cache/freentonic/chrome"
    --shm-size=256m
  )

  if [ "${VNC}" = "1" ]; then
    args+=(
      -p "127.0.0.1:5900:5900"
      -p "127.0.0.1:6080:6080"
      -e "FREENTONIC_VNC=1"
    )
  fi

  if [ -n "${FREENTONIC_SECRETS_FILE:-}" ]; then
    local real_path secrets_dir secrets_name
    real_path="$(cd "$(dirname "${FREENTONIC_SECRETS_FILE}")" && pwd)/$(basename "${FREENTONIC_SECRETS_FILE}")"
    secrets_dir="$(dirname "${real_path}")"
    secrets_name="$(basename "${real_path}")"
    args+=(
      -v "${secrets_dir}:/home/freentonic/.secrets:ro"
    )
    # The legacy entrypoint does not auto-wire secrets in `cli` mode, so
    # the caller must pass --secrets plain_file --secrets-file /home/freentonic/.secrets/${secrets_name}.
    echo "note: pass --secrets plain_file --secrets-file /home/freentonic/.secrets/${secrets_name}" >&2
  fi

  args+=("${IMAGE_NAME}" cli "$@")
  "${args[@]}"
}

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

subcommand="${1:-}"
case "${subcommand}" in
  server) shift; cmd_server "$@" ;;
  stop)   shift; cmd_stop   "$@" ;;
  logs)   shift; cmd_logs   "$@" ;;
  invoke) shift; cmd_invoke "$@" ;;
  cli)    shift; cmd_cli    "$@" ;;
  "")     usage ;;
  *)      echo "unknown subcommand: ${subcommand}" >&2; usage ;;
esac
