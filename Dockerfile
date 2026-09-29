# DeepSeek Harness in a container, reachable through an external reverse proxy.
#
# Upstream `dsh web` is deliberately loopback-only: the CLI rejects
# `--host 0.0.0.0` (packages/bundle/web-app/src/startup.ts) and the printed URL
# is always `http://127.0.0.1:<port>`. Behind Pangolin (or any proxy that is not
# on the same loopback) that is unreachable. This image keeps the upstream
# package untouched and changes only composition:
#
#   * `proxy.patch.yml` binds all interfaces via upstream's own `--patch` layer,
#     the documented opt-in for deployments that accept the exposure.
#   * `fix/owns-host.mjs` restores the Settings UI and prints the public URL.
#
# Nothing is forked and nothing is monkey-patched, so a new upstream RC is a
# rebuild, not a merge.
#
# syntax=docker/dockerfile:1

ARG BASE_IMAGE=node:22-bookworm-slim
FROM ${BASE_IMAGE}

# Release to ship. The tracking workflow overrides this with --build-arg; keep
# the default at the newest RC this repo publishes.
ARG DSH_VERSION=0.1.7-rc.2
# `dsh plugin add` and the Plugins settings page shell out to pnpm (resolved
# through PATH). Without it that page is dead; with it, plugin installs land in
# the state volume.
ARG PNPM_VERSION=12.6.0

LABEL org.opencontainers.image.title="deepseek-harness" \
      org.opencontainers.image.description="DeepSeek Harness (dsh) with a reverse-proxy-ready web UI" \
      org.opencontainers.image.source="https://github.com/prv-ctech/deepseek-harness" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${DSH_VERSION}" \
      com.prvctech.dsh.version="${DSH_VERSION}"

# tini = PID 1: reaps orphans and forwards SIGTERM so dsh's 5 s shutdown drain
# (PROCESS_SHUTDOWN_TIMEOUT_MS) actually runs. git/ca-certificates are what the
# agent's own tools expect to find. File staging and ownership tools bring
# util-linux' setpriv along (present in this base already).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git tini \
 && rm -rf /var/lib/apt/lists/*

# npm 10 on bookworm runs lifecycle scripts by default; the native addons dsh
# depends on ship prebuilt, so nothing compiles here and no --allow-scripts
# allowlist (needed on npm 11+) is required.
RUN npm install --global --omit=dev --no-audit --no-fund \
      "@deepseek-ai/dsh@${DSH_VERSION}" \
      "pnpm@${PNPM_VERSION}" \
 && npm cache clean --force

# Fail the build, not the deployment, if the published tarball is not the
# version this image claims to be.
RUN test "$(dsh --version)" = "${DSH_VERSION}"

# Optional Chrome variant: the same image plus a system Chrome, published as
# `deepseek-harness-chrome` (built with --build-arg INSTALL_CHROME=true).
# Installed from Google's own apt repo, so it is a real package at
# /usr/bin/google-chrome-stable: dsh-realbrowser's resolver finds a browser by
# name before any copy it downloads into the state volume, which makes that
# downloaded copy a fallback only. Chrome's version therefore follows the image
# build — bumping Chrome means rebuilding the image, which is the intended
# ownership model.
#
# fontconfig and fonts-liberation are named explicitly even though Chrome
# usually pulls them in: under --no-install-recommends a missing font makes
# Chrome abort with "FATAL:SkFontMgr_FontConfigInterface.cpp Not implemented"
# and signal 6 on any page containing a <form>, which surfaces misleadingly as
# "WebSocket closed: 1006". Listing them keeps that true regardless of what
# Chrome declares today.
#
# Latin-only is not enough to browse either: with just fonts-liberation a page
# in Japanese, Chinese, Korean or Arabic draws tofu — the glyphs are absent, so
# nothing errors and nothing renders. The Noto sets go in for that reason
# (noto-core covers Arabic, Hebrew, Devanagari, Thai and ~60 more scripts;
# noto-cjk covers Japanese, Korean and Simplified/Traditional Chinese;
# noto-color-emoji covers emoji), plus fonts-dejavu-core, the family
# fontconfig's own latin.conf prefers. Cost is roughly 145 MB installed, ~89 MB
# of it noto-cjk, and the smoke test asserts a representative coverage per
# package so a dropped font fails the build instead of a user's page.
#
# The hardened runtime is unaffected: nothing here needs exec from /tmp, so
# --read-only, --cap-drop ALL, no-new-privileges and a noexec /tmp all keep
# working. No browser flag belongs here either — the caller passes --no-sandbox,
# --disable-dev-shm-usage and the remote-debugging port, not the image.
ARG INSTALL_CHROME=false
LABEL com.prvctech.dsh.chrome="${INSTALL_CHROME}"
RUN if [ "$INSTALL_CHROME" = "true" ]; then \
      set -eux; \
      apt-get update; \
      apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
      install -d -m 0755 /etc/apt/keyrings; \
      curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg; \
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        google-chrome-stable fontconfig \
        fonts-liberation fonts-dejavu-core \
        fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji; \
      apt-get purge -y --auto-remove gnupg; \
      rm -rf /var/lib/apt/lists/*; \
    fi

ENV DSH_VERSION="${DSH_VERSION}" \
    DSH_HOME=/home/node/.dsh \
    HOME=/home/node \
    SHELL=/bin/bash \
    PNPM_HOME=/home/node/.dsh/pnpm \
    PUID=1000 \
    PGID=1000

# Keep every cache and store inside the state volume. Anything that resolves
# under a bare `$HOME` would otherwise try to write to the image layer and fail
# when the container runs with a read-only root filesystem.
#
# NARB_NATIVE_CACHE_DIR is load-bearing, not cosmetic: dsh's native addons are
# loaded through node-addon-native-custom-loader, which COPIES each prebuilt
# `.node` out of its package into `os.tmpdir()` and dlopens it from there
# (node-addon-native-custom-loader/lib/index.js). On a `--tmpfs /tmp:noexec`
# container — the normal hardened posture — that dlopen fails with
# "Cannot find module .../build/napi/napi-v9-linux-x64-gnu/require_builtin.node"
# and dsh never boots. Pointing the cache at the state volume (a real
# filesystem, exec allowed) keeps the noexec /tmp hardening usable.
ENV XDG_CACHE_HOME=/home/node/.dsh/cache \
    XDG_CONFIG_HOME=/home/node/.dsh/config \
    XDG_DATA_HOME=/home/node/.dsh/share \
    XDG_STATE_HOME=/home/node/.dsh/state \
    NARB_NATIVE_CACHE_DIR=/home/node/.dsh/cache/native

# The launcher layer and the plugin it inserts. The patch names the plugin by
# absolute path, so no package manager and no profile install are involved.
COPY proxy.patch.yml /opt/deepseek-harness/proxy.patch.yml
COPY fix/owns-host.mjs /opt/deepseek-harness/fix/owns-host.mjs

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# COPY preserves the source mode, and a restrictive umask produces 0600 files
# that the runtime user (a bare PUID) then cannot read.
RUN chmod 0644 /opt/deepseek-harness/proxy.patch.yml /opt/deepseek-harness/fix/owns-host.mjs \
 && chmod 0755 /usr/local/bin/docker-entrypoint.sh

# The agent's sandbox root is process.cwd(), so /workspace is both the working
# directory and the writable boundary of the sandbox. Both trees are created
# here already owned by the runtime user: Docker seeds a fresh named volume from
# the image's directory contents when that path exists, which is what makes an
# explicit `--user` run (no capabilities, so no chown at start) work.
WORKDIR /workspace
RUN mkdir -p "$DSH_HOME" "$PNPM_HOME" /workspace \
 && chown -R 1000:1000 "$DSH_HOME" /workspace

EXPOSE 3080

# No `USER`: the entrypoint starts as root only to fix ownership of the mounted
# volumes, then drops to PUID:PGID before dsh is executed. Running with
# `--user` is supported too (the entrypoint then skips the ownership step).
#
# The web UI answers 401 without a launch token and 303 on exchange, so both
# mean "server is up". No curl/wget in this base image; node is the client.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3080/').then(r=>process.exit([200,303,401].includes(r.status)?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
# Unraid's "Post Arguments" field REPLACES this CMD; the entrypoint re-adds the
# launcher layer, so `--port 3080 --no-open`-style overrides still work.
CMD ["web"]
