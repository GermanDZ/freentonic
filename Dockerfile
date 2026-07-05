# ─── builder stage: fetch noVNC + websockify ─────────────────────────────
# Isolated so git + its transitive deps don't end up in the final image.
# Pinned versions; bump when you want a noVNC UI refresh.
FROM debian:bookworm-slim AS novnc-builder

ARG NOVNC_REF=v1.5.0
ARG WEBSOCKIFY_REF=v0.12.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && git clone --depth 1 -b "${NOVNC_REF}"      https://github.com/novnc/noVNC       /opt/novnc \
  && git clone --depth 1 -b "${WEBSOCKIFY_REF}" https://github.com/novnc/websockify  /opt/novnc/utils/websockify \
  && rm -rf /opt/novnc/.git /opt/novnc/utils/websockify/.git /opt/novnc/tests


# ─── final stage ──────────────────────────────────────────────────────────
FROM ruby:3.2-slim-bookworm

# Chromium is PINNED to a known-good version, installed from a Debian
# snapshot. Debian bookworm-security *floats* the chromium package, so a
# bare `apt-get install chromium` picks up whatever is current at build
# time — and that silently broke us: 150.0.7871.46-1~deb12u1 SIGTRAPs
# (exit 133) on launch inside this container, while 148.0.7778.96-1~deb12u1
# runs fine. Because the image is rebuilt on every deploy, an unpinned
# browser means an external dependency can take the whole bridge down with
# no code change. The snapshot pin makes the browser reproducible; bump
# CHROMIUM_VERSION + CHROMIUM_SNAPSHOT deliberately after testing a newer
# build (see docs — build to a throwaway tag and run a `--dump-dom
# about:blank` smoke test before promoting).
#
# The exact version lives only in the snapshot once the live security repo
# rolls forward, so we add a snapshot apt source for the install, request
# the exact version (apt also pulls the strict-versioned chromium-common
# from the same snapshot), hold it, then drop the snapshot source again.
ARG CHROMIUM_VERSION=148.0.7778.96-1~deb12u1
# snapshot.debian.org state carrying that chromium in bookworm-security.
ARG CHROMIUM_SNAPSHOT=20260507T164458Z

# procps for pgrep (ChromeCdp process management), fonts for page
# rendering, xvfb + x11vnc for non-headless mode, tini so PID 1 reaps the
# per-invoke children, python3 so websockify runs (pure-python).
RUN echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/${CHROMIUM_SNAPSHOT}/ bookworm-security main" \
      > /etc/apt/sources.list.d/snapshot-chromium.list \
  && apt-get -o Acquire::Check-Valid-Until=false update \
  && apt-get install -y --no-install-recommends \
    chromium="${CHROMIUM_VERSION}" \
    procps \
    fonts-liberation \
    fonts-dejavu-core \
    ca-certificates \
    xvfb \
    x11vnc \
    tini \
    python3 \
  && apt-mark hold chromium \
  && rm -f /etc/apt/sources.list.d/snapshot-chromium.list \
  && rm -rf /var/lib/apt/lists/*

# Non-root user for defense-in-depth.
#
# Stable explicit uid (vs `useradd -r`'s Debian-dynamic system uid) so
# volumes are owned predictably across rebuilds, and so sibling
# containers that share `/workspace/runs` or `/home/freentonic/workflows`
# (e.g. simplefreen's bridge) can mount them under the same uid and
# avoid cross-uid permission games.
ARG FREENTONIC_UID=10001
RUN groupadd -g ${FREENTONIC_UID} freentonic \
 && useradd  -u ${FREENTONIC_UID} -g ${FREENTONIC_UID} -m -s /bin/bash freentonic

# noVNC static assets + websockify. Runs under the freentonic user at
# runtime; read-only access is enough.
COPY --from=novnc-builder /opt/novnc /opt/novnc

WORKDIR /opt/freentonic
COPY lib/ lib/
COPY bin/ bin/
COPY examples/ examples/

# Workflows bind-mount target. Operator mounts a host directory (read-only)
# containing provider workflow YAMLs here at runtime.
RUN mkdir -p /home/freentonic/workflows && chown freentonic:freentonic /home/freentonic/workflows

# Per-run artifact root. Operator mounts a host directory here so the web
# app can read screenshots and logs directly from its local filesystem.
RUN mkdir -p /workspace/runs && chown -R freentonic:freentonic /workspace

# Chrome profile root — mount a named volume to persist login state across
# container restarts. Subdirectories per (workflow, credential) pair are
# created on demand by the invoke runner.
RUN mkdir -p /home/freentonic/.cache/freentonic/chrome \
  && chown -R freentonic:freentonic /home/freentonic/.cache

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER freentonic
ENV HOME=/home/freentonic
ENV PATH="/opt/freentonic/bin:${PATH}"

# 5900: raw VNC (optional, debug).
# 6080: noVNC HTML client (optional, debug) — same content as 5900, over HTTP+WebSocket.
# 7878: invoke HTTP server.
EXPOSE 5900 6080 7878

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
