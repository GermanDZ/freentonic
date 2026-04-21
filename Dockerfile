FROM ruby:3.2-slim-bookworm

# Chromium for CDP, procps for pgrep (used by ChromeCdp process management),
# fonts for proper page rendering, xvfb + x11vnc for non-headless mode,
# tini so PID 1 reaps the per-invoke child processes cleanly.
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    procps \
    fonts-liberation \
    fonts-dejavu-core \
    ca-certificates \
    xvfb \
    x11vnc \
    tini \
  && rm -rf /var/lib/apt/lists/*

# Non-root user for defense-in-depth.
RUN groupadd -r freentonic && useradd -r -g freentonic -m -s /bin/bash freentonic

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

# 5900: optional VNC (debug). 7878: invoke HTTP server.
EXPOSE 5900 7878

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
