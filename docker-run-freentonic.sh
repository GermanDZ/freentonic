#!/bin/bash
set -euo pipefail

IMAGE_NAME="${FREENTONIC_IMAGE:-freentonic:latest}"
SECRETS_FILE="${FREENTONIC_SECRETS_FILE:-}"
PROVIDERS_VOLUME="${FREENTONIC_PROVIDERS_VOLUME:-freentonic-providers}"
CHROME_PROFILE_VOLUME="${FREENTONIC_CHROME_PROFILE_VOLUME:-freentonic-chrome-profile}"
VNC="${FREENTONIC_VNC:-0}"

TTY_FLAG=""
if [ -t 0 ]; then
  TTY_FLAG="-t"
fi

DOCKER_ARGS=(
  docker run --rm -i ${TTY_FLAG}
  -v "$(pwd):/workspace"
  -v "${PROVIDERS_VOLUME}:/home/freentonic/providers"
  -v "${CHROME_PROFILE_VOLUME}:/home/freentonic/.cache/freentonic/chrome"
  --shm-size=256m
)

# VNC mode: expose port for interactive debugging.
if [ "${VNC}" = "1" ]; then
  DOCKER_ARGS+=(-p 5900:5900 -e "FREENTONIC_VNC=1")
fi

# If a secrets file is set, mount its parent directory read-only.
# The entrypoint copies the file with correct ownership/permissions and injects
# --secrets plain_file --secrets-file automatically.
if [ -n "${SECRETS_FILE}" ]; then
  REAL_PATH="$(cd "$(dirname "${SECRETS_FILE}")" && pwd)/$(basename "${SECRETS_FILE}")"
  SECRETS_DIR="$(dirname "${REAL_PATH}")"
  SECRETS_NAME="$(basename "${REAL_PATH}")"
  DOCKER_ARGS+=(
    -v "${SECRETS_DIR}:/home/freentonic/.secrets:ro"
    -e "FREENTONIC_SECRETS_MOUNT=/home/freentonic/.secrets/${SECRETS_NAME}"
  )
fi

# Allow overriding provider repo/ref.
[ -n "${FREENTONIC_PROVIDERS_REPO:-}" ] && DOCKER_ARGS+=(-e "FREENTONIC_PROVIDERS_REPO=${FREENTONIC_PROVIDERS_REPO}")
[ -n "${FREENTONIC_PROVIDERS_REF:-}" ] && DOCKER_ARGS+=(-e "FREENTONIC_PROVIDERS_REF=${FREENTONIC_PROVIDERS_REF}")

"${DOCKER_ARGS[@]}" "${IMAGE_NAME}" "$@"
