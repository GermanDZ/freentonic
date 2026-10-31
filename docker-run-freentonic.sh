#!/bin/bash
# Freentonic container helper.
#
# Subcommands:
#   server              Start the long-running invoke server in the background.
#   stop                Stop and remove the running container.
#   logs                Follow container logs.
#   invoke REQ_JSON     POST /invoke with the JSON file at REQ_JSON.
#   cli ARGS...         One-shot CLI run (legacy path, no server).
#   author ARGS...      Held-open authoring loop: mount a writable workspace,
#                       serve noVNC with a static password, drop into a shell.
#   author-shell        Open another bash shell into the running author container.
#
# Env vars:
#   FREENTONIC_IMAGE           image tag (default freentonic:latest)
#   FREENTONIC_WORKFLOWS_DIR   host path to mount at /home/freentonic/workflows (REQUIRED for server)
#   FREENTONIC_AUTHOR_DIR      host path to mount RW at /home/freentonic/authoring (REQUIRED for author;
#                              refused if inside a git work tree — recordings hold live session data)
#   FREENTONIC_VNC_PASSWORD    static noVNC password for cli/author modes (random, printed once, if unset)
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
AUTHOR_CONTAINER_NAME="${FREENTONIC_AUTHOR_CONTAINER_NAME:-freentonic-author}"
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

# Refuse a workspace directory that lives inside a git work tree. The
# authoring workspace collects live financial data — recording.jsonl, request
# dumps, --dump-raw output — so a dir under version control invites a stray
# `git add` that commits a real bank session. `git rev-parse
# --is-inside-work-tree` catches both classic repos (a `.git` directory) and
# linked worktrees (a `.git` file), which the Ruby dump_requests guard's
# `.git`-dir-only walk misses. If git is absent the check simply passes — the
# dir can't be in a work tree we can't detect, and umask 0077 still applies.
refuse_if_in_git_worktree() {
  local dir="$1"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: FREENTONIC_AUTHOR_DIR=${dir} is inside a git work tree." >&2
    echo "       The authoring workspace captures live session data (recording.jsonl," >&2
    echo "       request dumps); refusing so a recording can't be committed by reflex." >&2
    echo "       Point FREENTONIC_AUTHOR_DIR at a directory outside any git repo." >&2
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

cmd_author() {
  # Held-open authoring loop. Mounts a writable workspace, serves noVNC with a
  # static password, and drops into a shell where the record → compile → lint →
  # step tools all run against the mounted dir. Unlike `cli` (one-shot,
  # read-only workflows) and `server` (read-only workflows, per-invoke rotated
  # VNC password), `author` keeps one container alive so you iterate in place.
  require_env FREENTONIC_AUTHOR_DIR "host path to the writable authoring workspace"
  local author_dir
  author_dir="$(cd "${FREENTONIC_AUTHOR_DIR}" 2>/dev/null && pwd || true)"
  if [ -z "${author_dir}" ] || [ ! -d "${author_dir}" ]; then
    echo "error: FREENTONIC_AUTHOR_DIR=${FREENTONIC_AUTHOR_DIR} is not a directory" >&2
    exit 2
  fi
  # A recording.jsonl full of live session data must not be one `git add` away.
  refuse_if_in_git_worktree "${author_dir}"

  # One named session at a time. If it's already up, a second `docker run
  # --name` would just error on the name clash — point the operator at the
  # shell helper (or a clean restart) instead.
  if docker ps --format '{{.Names}}' | grep -qx "${AUTHOR_CONTAINER_NAME}"; then
    echo "note: author container '${AUTHOR_CONTAINER_NAME}' is already running." >&2
    echo "      open another shell into it:  $0 author-shell" >&2
    echo "      restart it fresh:            docker rm -f ${AUTHOR_CONTAINER_NAME}, then re-run" >&2
    exit 2
  fi

  local tty_flag=""
  if [ -t 0 ]; then tty_flag="-t"; fi

  # Inherit cmd_server's hardening — the author container holds live financial
  # data on a writable mount, so it follows the server's locked-down posture,
  # NOT cmd_cli's un-hardened shape. The one relaxation is the workspace mount
  # itself (RW is the point); the rootfs stays read-only and every artifact is
  # routed to the workspace by FREENTONIC_RUN_DIR (set in the entrypoint's
  # author branch), so nothing needs to write the rootfs.
  local args=(
    docker run --rm -i ${tty_flag}
    --name "${AUTHOR_CONTAINER_NAME}"
    # Set the container hostname to `localhost` so noVNC's own novnc_proxy
    # "Navigate to this URL" line resolves from the host. novnc_proxy (v1.5.0)
    # bakes $(hostname) into that URL; without this it prints the container ID
    # (e.g. http://43801bc326ce:6080/...host=43801bc326ce), which only resolves
    # inside the container. The base image's `127.0.0.1 localhost` /etc/hosts
    # entry still wins for in-container lookups (websockify→x11vnc, CDP).
    --hostname localhost
    -v "${author_dir}:/home/freentonic/authoring"
    # No shared chrome-profile volume for author mode: the entrypoint points
    # FREENTONIC_CHROME_PROFILE_DIR at .chrome-profile inside this writable
    # workspace mount instead. That mount is always writable regardless of the
    # container uid, so author mode can't hit the shared volume's stale-ownership
    # crash, and each workspace keeps its own login/device-trust state.
    --shm-size=256m
    --cap-drop ALL
    --security-opt no-new-privileges
    --read-only
    --tmpfs /tmp
    --tmpfs /home/freentonic/.config
    --tmpfs /home/freentonic/.local
    --tmpfs /home/freentonic/.pki
  )

  # noVNC is the whole point of author mode (you watch Chrome drive the bank),
  # so VNC defaults on. Loopback-only publish, as everywhere. Forward a static
  # password if the operator set one — the wrapper does NOT forward
  # FREENTONIC_VNC_PASSWORD in any other mode; here it must, so the noVNC URL
  # has a known password instead of a per-run random one to hunt for in logs.
  if [ "${VNC}" = "1" ]; then
    args+=(
      -p "127.0.0.1:5900:5900"
      -p "127.0.0.1:6080:6080"
      -e "FREENTONIC_VNC=1"
    )
    if [ -n "${FREENTONIC_VNC_PASSWORD:-}" ]; then
      # Name only: docker reads the value from this environment, so it
      # never appears in `ps` or the docker command line.
      export FREENTONIC_VNC_PASSWORD
      args+=(-e FREENTONIC_VNC_PASSWORD)
    fi
  fi

  args+=("${IMAGE_NAME}" author "$@")

  echo "authoring workspace: ${author_dir} → /home/freentonic/authoring (read-write)"
  echo "  edit files in ${author_dir} on the host — they appear live in the container, no copy needed."
  echo "  open another shell into this session:  $0 author-shell"
  if [ "${VNC}" = "1" ]; then
    echo "noVNC at http://127.0.0.1:6080/vnc.html?host=localhost&port=6080&autoconnect=true"
    echo "WARNING: noVNC exposes a LIVE bank session to anyone who can reach this loopback port."
    if [ -z "${FREENTONIC_VNC_PASSWORD:-}" ]; then
      echo "         No FREENTONIC_VNC_PASSWORD set — the container prints a random one to these logs."
    fi
  fi
  "${args[@]}"
}

cmd_author_shell() {
  # Open another interactive bash shell inside the running author container,
  # so a second terminal (or an agent) works the same held-open Chrome the
  # first terminal watches over noVNC. The workspace mount and PATH are the
  # entrypoint's, so `freentonic` resolves and cwd is /home/freentonic/authoring.
  if ! docker ps --format '{{.Names}}' | grep -qx "${AUTHOR_CONTAINER_NAME}"; then
    echo "error: no running author container named '${AUTHOR_CONTAINER_NAME}'." >&2
    echo "       start one first:  FREENTONIC_AUTHOR_DIR=/path/to/workspace $0 author" >&2
    exit 2
  fi
  # A `docker exec` shell inherits only the image's ENV, not the entrypoint's
  # runtime exports — so pass the two the authoring loop needs: DISPLAY (headed
  # Chrome for --recording/--step; the entrypoint's Xvfb is on :99) and
  # FREENTONIC_RUN_DIR (routes recording.jsonl/screenshots/etc. to the mounted
  # workspace). DISPLAY is also baked into the image ENV now; this keeps
  # author-shell working against an older image that predates that.
  exec docker exec -it \
    -w /home/freentonic/authoring \
    -e DISPLAY=:99 \
    -e FREENTONIC_RUN_DIR=/home/freentonic/authoring \
    -e FREENTONIC_CHROME_PROFILE_DIR=/home/freentonic/authoring/.chrome-profile \
    -e FREENTONIC_NO_SANDBOX=1 \
    -e "FREENTONIC_RECORD_DOM=${FREENTONIC_RECORD_DOM:-1}" \
    "${AUTHOR_CONTAINER_NAME}" bash
}

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# Dispatch only when executed directly. When sourced (the guard/helper unit
# tests do this to exercise refuse_if_in_git_worktree in isolation), skip the
# case so sourcing has no side effects.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  subcommand="${1:-}"
  case "${subcommand}" in
    server) shift; cmd_server "$@" ;;
    stop)   shift; cmd_stop   "$@" ;;
    logs)   shift; cmd_logs   "$@" ;;
    invoke) shift; cmd_invoke "$@" ;;
    cli)    shift; cmd_cli    "$@" ;;
    author) shift; cmd_author "$@" ;;
    author-shell) shift; cmd_author_shell "$@" ;;
    "")     usage ;;
    *)      echo "unknown subcommand: ${subcommand}" >&2; usage ;;
  esac
fi
