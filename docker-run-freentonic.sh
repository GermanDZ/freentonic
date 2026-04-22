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
#   FREENTONIC_INVOKE_TOKEN    bearer token for /invoke (REQUIRED for server)
#   FREENTONIC_LISTEN_PORT     host port to expose the invoke server on (default 7878)
#   FREENTONIC_CONTAINER_NAME  container name (default freentonic-server)
#   FREENTONIC_VNC             0|1 (default 1) — expose VNC on 5900 for debug. Set to 0 to skip.
#   FREENTONIC_CHROME_PROFILE_VOLUME  Docker volume name for the Chrome profile root
#                                     (default freentonic-chrome-profile)
#
# SimpleFIN bridge (optional — see docs/simplefin-bridge.md):
#   FREENTONIC_SIMPLEFIN_ENABLED  0|1 — enables the SimpleFIN routes + admin UI.
#   FREENTONIC_SIMPLEFIN_DIR      host path bind-mounted at /workspace/simplefin
#                                 (default: $(pwd)/freentonic-simplefin).
#   FREENTONIC_SECRETS_KEY        32-byte base64 master key (REQUIRED when enabled).
#   FREENTONIC_ADMIN_PASSWORD     admin UI / admin API bearer (REQUIRED when enabled).
#   FREENTONIC_PUBLIC_URL         external URL Actual will reach (REQUIRED when enabled).

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
  require_env FREENTONIC_INVOKE_TOKEN  "bearer token protecting /invoke"

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
    -e "FREENTONIC_INVOKE_TOKEN=${FREENTONIC_INVOKE_TOKEN}"
  )

  if [ "${VNC}" = "1" ]; then
    args+=(
      -p "127.0.0.1:5900:5900"
      -p "127.0.0.1:6080:6080"
      -e "FREENTONIC_VNC=1"
    )
  fi

  # Optional SimpleFIN bridge. When enabled, require the three secrets env
  # vars and bind-mount a host directory for the encrypted-at-rest state.
  if [ "${FREENTONIC_SIMPLEFIN_ENABLED:-0}" = "1" ]; then
    require_env FREENTONIC_SECRETS_KEY    "32-byte base64 master key for SimpleFIN credential storage"
    require_env FREENTONIC_ADMIN_PASSWORD "admin UI / admin API bearer password"
    require_env FREENTONIC_PUBLIC_URL     "external URL actual-server will reach (e.g. https://freentonic.example.com)"

    local simplefin_dir
    simplefin_dir="${FREENTONIC_SIMPLEFIN_DIR:-$(pwd)/freentonic-simplefin}"
    mkdir -p "${simplefin_dir}"
    chmod 0700 "${simplefin_dir}" 2>/dev/null || true
    simplefin_dir="$(cd "${simplefin_dir}" && pwd)"

    args+=(
      -v "${simplefin_dir}:/workspace/simplefin"
      -e "FREENTONIC_SIMPLEFIN_ENABLED=1"
      -e "FREENTONIC_SECRETS_KEY=${FREENTONIC_SECRETS_KEY}"
      -e "FREENTONIC_ADMIN_PASSWORD=${FREENTONIC_ADMIN_PASSWORD}"
      -e "FREENTONIC_PUBLIC_URL=${FREENTONIC_PUBLIC_URL}"
    )
    echo "SimpleFIN bridge enabled (state dir: ${simplefin_dir})"
  fi

  args+=("${IMAGE_NAME}")

  echo "starting ${CONTAINER_NAME} (workflows=${workflows_dir}, runs=${runs_dir})"
  "${args[@]}"
  echo "listening on http://127.0.0.1:${LISTEN_PORT}"
  if [ "${FREENTONIC_SIMPLEFIN_ENABLED:-0}" = "1" ]; then
    echo "admin UI at http://127.0.0.1:${LISTEN_PORT}/admin/ (password: \$FREENTONIC_ADMIN_PASSWORD)"
  fi
  if [ "${VNC}" = "1" ]; then
    echo "noVNC at http://127.0.0.1:6080/vnc.html"
    if [ "${FREENTONIC_SIMPLEFIN_ENABLED:-0}" = "1" ]; then
      echo "  server mode: the VNC password is minted per headed sync —"
      echo "  click 'Re-authenticate (VNC)' in the admin UI to get one."
    else
      echo "  server mode: VNC is locked between invokes; pass"
      echo "  {\"vnc_password\": \"...\"} on /invoke to unlock for one run."
    fi
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
