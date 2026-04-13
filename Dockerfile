FROM ruby:3.2-slim-bookworm

# Chromium for CDP, procps for pgrep (used by ChromeCdp process management),
# fonts for proper page rendering, git for cloning providers at first startup.
# xvfb + x11vnc for non-headless mode inside Docker (VNC into the container).
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    procps \
    fonts-liberation \
    fonts-dejavu-core \
    git \
    ca-certificates \
    xvfb \
    x11vnc \
  && rm -rf /var/lib/apt/lists/*

# Non-root user for defense-in-depth.
RUN groupadd -r freentonic && useradd -r -g freentonic -m -s /bin/bash freentonic

WORKDIR /opt/freentonic
COPY lib/ lib/
COPY bin/ bin/
COPY examples/ examples/

# Providers will be cloned at runtime into this directory.
RUN mkdir -p /home/freentonic/providers && chown freentonic:freentonic /home/freentonic/providers

# Output directory — mount from host via -v $(pwd):/workspace.
RUN mkdir -p /workspace && chown freentonic:freentonic /workspace

# Optional secrets directory mount point.
RUN mkdir -p /home/freentonic/.secrets && chown freentonic:freentonic /home/freentonic/.secrets

# Chrome profile directory — mount a named volume to persist login state.
RUN mkdir -p /home/freentonic/.cache/freentonic/chrome \
  && chown -R freentonic:freentonic /home/freentonic/.cache

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER freentonic
ENV HOME=/home/freentonic
ENV PATH="/opt/freentonic/bin:${PATH}"

EXPOSE 5900

ENTRYPOINT ["docker-entrypoint.sh"]
