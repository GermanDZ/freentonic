#!/bin/bash
set -euo pipefail

PROVIDERS_DIR="${HOME}/providers/freentonic-providers"
PROVIDERS_REPO="${FREENTONIC_PROVIDERS_REPO:-https://github.com/GermanDZ/freentonic-providers.git}"
PROVIDERS_REF="${FREENTONIC_PROVIDERS_REF:-main}"

# Skip provider cloning for --version, --help, or --purge.
SKIP_PROVIDERS=false
for arg in "$@"; do
  case "$arg" in
    --version|--help|-h|--purge) SKIP_PROVIDERS=true ;;
  esac
done

if [ "${SKIP_PROVIDERS}" = false ] && [ "${FREENTONIC_SKIP_PROVIDERS:-}" != "1" ]; then
  if [ ! -d "${PROVIDERS_DIR}/.git" ]; then
    echo "[entrypoint] Cloning freentonic-providers (${PROVIDERS_REF})..."
    if ! git clone --depth 1 --branch "${PROVIDERS_REF}" "${PROVIDERS_REPO}" "${PROVIDERS_DIR}" 2>&1; then
      echo "[entrypoint] Warning: could not clone providers. Mount workflows manually or set FREENTONIC_PROVIDERS_REPO."
    fi
  else
    echo "[entrypoint] Updating freentonic-providers..."
    cd "${PROVIDERS_DIR}"
    git pull --ff-only 2>/dev/null || echo "[entrypoint] Warning: providers pull failed, using cached version"
    cd - > /dev/null
  fi
fi

# If a secrets file was mounted via the wrapper, copy it to a location owned by
# the container user and wire up the --secrets flags automatically.
SECRETS_ARGS=()
if [ -n "${FREENTONIC_SECRETS_MOUNT:-}" ] && [ -f "${FREENTONIC_SECRETS_MOUNT}" ]; then
  SECRETS_COPY="/tmp/freentonic-secrets.env"
  cp "${FREENTONIC_SECRETS_MOUNT}" "${SECRETS_COPY}"
  chmod 600 "${SECRETS_COPY}"
  SECRETS_ARGS=(--secrets plain_file --secrets-file "${SECRETS_COPY}")
fi

# Always use Xvfb virtual display — gives Chrome a real display context which
# passes behavioral captchas that reject headless mode. Xvfb is lightweight
# (~8MB RAM for the framebuffer).
# VNC server is opt-in via FREENTONIC_VNC=1 for interactive debugging.
Xvfb :99 -screen 0 1920x1080x24 &>/dev/null &
export DISPLAY=:99
sleep 0.3

if [ "${FREENTONIC_VNC:-0}" = "1" ]; then
  x11vnc -display :99 -forever -passwd freentonic -quiet &
  sleep 0.3
  echo "[entrypoint] VNC server ready. Connect with:"
  echo "[entrypoint]   macOS:  open vnc://localhost:5900"
  echo "[entrypoint]   Linux:  vncviewer localhost:5900"
  echo "[entrypoint]   Password: freentonic"
fi

exec ruby -I/opt/freentonic/lib /opt/freentonic/bin/freentonic \
  --no-sandbox \
  "${SECRETS_ARGS[@]+"${SECRETS_ARGS[@]}"}" \
  "$@"
