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
ARG DSH_VERSION=0.2.0-rc.2
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

# Browser layer of the "+" variant: a system Chrome, installed from Google's
# own apt repo, so it is a real package at
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
ARG INSTALL_PLUS=false
LABEL com.prvctech.dsh.plus="${INSTALL_PLUS}"
RUN if [ "$INSTALL_PLUS" = "true" ]; then \
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

# Optional "+" variant, published as `deepseek-harness-plus` (--build-arg
# INSTALL_PLUS=true). It is the base image plus the browser layer above and
# four things a plugin, a task or the MCP configuration can discover instead of
# downloading into the state volume:
#
#   1. Python 3.11 + pip, so a tool that probes for `python3` finds one. Plugins
#      are npm packages, but everything they shell out to — analysis scripts,
#      androguard, a decompiler's helper — is usually Python.
#   2. rtk, the token-saving output filter (github.com/rtk-ai/rtk).
#   3. The Android RE toolchain: jadx, apktool, smali/baksmali, enjarify, aapt,
#      dexdump, apksigner, zipalign.
#   4. codebase-memory-mcp (github.com/DeusData/codebase-memory-mcp), the code
#      intelligence MCP server, on PATH and at the path the MCP configuration
#      runs it from.
#
# The browser layer and this layer are one variant: INSTALL_PLUS=true selects
# both, so they cannot drift apart.
#
# Cost: roughly 1 GB over the base image. openjdk-17-jre-headless alone
# is 188 MB installed, and that JVM is not optional dressing — jadx, apktool,
# smali and apksigner are all Java, so one shared JRE is cheaper than four.
# codebase-memory-mcp is another 286 MB on its own.
#
# Version pins are ARGs, not hardcoded strings, so a rebuild of an existing DSH
# release can move them without touching this layer; each pin is restated with
# the evidence that justifies it.
#
# rtk: the musl tarball, not the .deb the same release publishes. The .deb
# declares `libc6 (>= 2.39)`; bookworm ships glibc 2.36, so `dpkg -i` would fail
# the build. The musl build is statically linked (verified: `ldd` reports "not a
# dynamic executable"), which also keeps it independent of the base image. The
# checksum is the one in the release's own checksums.txt for this exact asset, so
# a swapped upload fails here rather than at first use.
#
# jadx: 1.5.6 is the newest stable release. Upstream ships no checksums, so this
# layer verifies by running it — `jadx --version` must answer, which also proves
# the shared openjdk-17 JRE is new enough for it (jadx 1.5.x needs 11+). The
# upstream `bin/jadx` launcher is installed as-is: its default JVM flags are
# accepted by Java 17, so no wrapper is needed.
#
# apktool is the package that pulls the rest of the Android side in: it depends
# on aapt, android-framework-res, libsmali-java and default-jre-headless, and
# libsmali-java + java-wrappers put `smali` and `baksmali` on PATH as real
# commands. dexdump, apksigner and zipalign are named explicitly alongside it so
# the set is readable in one place rather than spread across dependency
# resolution. enjarify is dex→jar in pure Python, and stands in for dex2jar,
# which bookworm does not package at all.
#
# The symlink loop at the end is load-bearing, not tidiness: aapt, aapt2,
# dexdump, apksigner and zipalign install to
# /usr/lib/android-sdk/build-tools/debian/ and Debian ships no /usr/bin entries
# or update-alternatives for them, so without these links they exist and cannot
# be run. Only the amd64 build-tools directory is linked, matching the amd64-only
# publication of this image.
#
# androguard is the one analysis tool worth preinstalling: it is the only one
# here that answers structured questions about an APK (manifest, certificates,
# classes, strings) from a script, and it is how a "what is in this APK" question
# gets answered without a hand-written parser. It is installed at build time
# deliberately — a runtime `pip install` cannot work in the default posture,
# because the Landlock sandbox grants writes only under /workspace and /tmp and
# a system-wide install targets /usr/local/lib/python3.11/dist-packages. Debian's
# pip is also PEP 668 externally-managed, hence --break-system-packages here and
# PIP_BREAK_SYSTEM_PACKAGES below, which is what makes the agent's own
# `pip install --user` calls work.
#
# codebase-memory-mcp: the portable tarball — the fully static build (`ldd`
# reports "not a dynamic executable"), so it runs whatever glibc the base image
# ships, the same reason rtk comes from its musl tarball. The checksum is the
# release's own checksums.txt entry for this exact asset. It is installed at
# /usr/local/bin/codebase-memory-mcp — image-owned, on PATH, and not shadowable
# by a volume mount or by a $HOME the runtime uid does not own — with
# /home/node/.local/bin/codebase-memory-mcp symlinked to it. The MCP
# configuration runs the symlink's path (`command: …, args: []`), and the link
# is what keeps that row working even if it predates this layout: a config in
# the state volume outlives image updates, so config/image path drift has to
# resolve rather than strand the server. Upstream publishes the binary
# unstripped (~286 MB) and it is installed byte-for-byte as published, so the
# release's checksums and attestations still describe what runs. CBM_CACHE_DIR
# below is the one thing this tool needs from the image: its cache root defaults
# to `~/.cache/codebase-memory-mcp` and ignores XDG_CACHE_HOME.
#
# The hardened runtime is unaffected: every one of these tools reads the APK and
# writes under $HOME or the workspace. Nothing here execs from /tmp, so
# --read-only, --cap-drop ALL, no-new-privileges and a noexec /tmp all keep
# working.
ARG RTK_VERSION=0.50.0
ARG RTK_SHA256=bc2b8902b0d9c796c82ef45f16ae2307e17757afeca5ee156235a3dc7bda5f89
ARG JADX_VERSION=1.5.6
ARG ANDROGUARD_VERSION=4.1.4
ARG CBM_VERSION=0.11.0
ARG CBM_SHA256=1f9e8293eb2bc5c05cfa27a7e8fc033da6d729ffad525ccfcdaa3fd606306683
RUN if [ "$INSTALL_PLUS" = "true" ]; then \
      set -eux; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        ca-certificates curl \
        python3 python3-pip python3-venv python3-dev \
        openjdk-17-jre-headless \
        apktool aapt dexdump apksigner zipalign enjarify \
        unzip file; \
      curl -fsSLo /tmp/rtk.tar.gz \
        "https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/rtk-x86_64-unknown-linux-musl.tar.gz"; \
      echo "${RTK_SHA256}  /tmp/rtk.tar.gz" | sha256sum -c -; \
      tar -xzf /tmp/rtk.tar.gz -C /usr/local/bin rtk; \
      chmod 0755 /usr/local/bin/rtk; \
      curl -fsSLo /tmp/jadx.zip \
        "https://github.com/skylot/jadx/releases/download/v${JADX_VERSION}/jadx-${JADX_VERSION}.zip"; \
      unzip -q /tmp/jadx.zip -d /opt/jadx; \
      ln -s /opt/jadx/bin/jadx /usr/local/bin/jadx; \
      /usr/local/bin/jadx --version; \
      python3 -m pip install --break-system-packages --no-cache-dir \
        "androguard==${ANDROGUARD_VERSION}"; \
      python3 -c 'import androguard; print(androguard.__version__)'; \
      mkdir -p /home/node/.local/bin; \
      curl -fsSLo /tmp/cbm.tar.gz \
        "https://github.com/DeusData/codebase-memory-mcp/releases/download/v${CBM_VERSION}/codebase-memory-mcp-linux-amd64-portable.tar.gz"; \
      echo "${CBM_SHA256}  /tmp/cbm.tar.gz" | sha256sum -c -; \
      tar -xzf /tmp/cbm.tar.gz -C /usr/local/bin codebase-memory-mcp; \
      chmod 0755 /usr/local/bin/codebase-memory-mcp; \
      ln -s /usr/local/bin/codebase-memory-mcp /home/node/.local/bin/codebase-memory-mcp; \
      test "$(/home/node/.local/bin/codebase-memory-mcp --version)" = "codebase-memory-mcp ${CBM_VERSION}"; \
      for tool in aapt aapt2 dexdump apksigner zipalign; do \
        ln -s "/usr/lib/android-sdk/build-tools/debian/${tool}" "/usr/local/bin/${tool}"; \
      done; \
      rm -f /tmp/rtk.tar.gz /tmp/jadx.zip /tmp/cbm.tar.gz; \
      rm -rf /var/lib/apt/lists/* /root/.cache; \
    fi

# Native Selkies includes its web client and capture/codec extensions. Its
# Bookworm package reuses Python 3.11; no GStreamer, desktop or vendor driver.
# Default wheels bundle GPL-enabled x264/x265/FFmpeg: see docs/selkies.md before
# redistribution. Runtime stays off unless DSH_GRAPHICS_ENABLED=true.
ARG SELKIES_VERSION=2.0.0
ARG SELKIES_SHA256=fd02cbc08b94eb65f5e834c11849084eec605564d5964f2500dc1209425dc620
RUN if [ "$INSTALL_PLUS" = "true" ]; then \
      set -eux; \
      apt-get update; \
      curl -fsSLo /tmp/selkies.deb \
        "https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/selkies-${SELKIES_VERSION}-bookworm-amd64.deb"; \
      echo "${SELKIES_SHA256}  /tmp/selkies.deb" | sha256sum -c -; \
      apt-get install -y --no-install-recommends \
        /tmp/selkies.deb xvfb xauth x11-utils x11-xserver-utils \
        pulseaudio pulseaudio-utils openbox iproute2; \
      test "$(dpkg-query -W -f='${Version}' selkies)" = "${SELKIES_VERSION}-1~bookworm"; \
      /opt/selkies/bin/python3 -c 'import selkies, pixelflux, pcmflux'; \
      rm -f /tmp/selkies.deb; \
      rm -rf /var/lib/apt/lists/*; \
    fi

# PIP_BREAK_SYSTEM_PACKAGES is the only concession the -plus toolchain asks for:
# Debian's Python 3.11 is marked PEP 668 externally-managed, so every `pip
# install` in this image is refused without it — including the agent's own. It is
# inert in the base image, which ships no pip. Note what it does not
# buy: anything meant to outlive a run still has to write under $HOME (the
# XDG_CACHE_HOME below) or the workspace, because a system-wide install targets
# /usr/local/lib/python3.11/dist-packages, which the workspace-write sandbox does
# not grant. `pip install --user` is the install that works from inside it.
ENV DSH_VERSION="${DSH_VERSION}" \
    DSH_HOME=/home/node/.dsh \
    HOME=/home/node \
    SHELL=/bin/bash \
    PNPM_HOME=/home/node/.dsh/pnpm \
    PUID=1000 \
    PGID=1000 \
    PIP_BREAK_SYSTEM_PACKAGES=1

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
#
# CBM_CACHE_DIR is the same redirection for codebase-memory-mcp in the -plus
# image, and it is load-bearing for the same class of reason. The tool's cache
# root defaults to ~/.cache/codebase-memory-mcp and does NOT follow
# XDG_CACHE_HOME (verified: with XDG_CACHE_HOME pointed elsewhere it still
# created ~/.cache/codebase-memory-mcp), so left alone the indexes land in the
# image layer — unwritable under a read-only root filesystem, and not even
# creatable when the runtime uid does not own /home/node (Unraid's 99:100).
# Pointed at the state volume they are writable by whoever the entrypoint
# chowns it for, and they survive a container upgrade. It is inert in the base
# image, which ships no codebase-memory-mcp.
ENV XDG_CACHE_HOME=/home/node/.dsh/cache \
    XDG_CONFIG_HOME=/home/node/.dsh/config \
    XDG_DATA_HOME=/home/node/.dsh/share \
    XDG_STATE_HOME=/home/node/.dsh/state \
    NARB_NATIVE_CACHE_DIR=/home/node/.dsh/cache/native \
    CBM_CACHE_DIR=/home/node/.dsh/cache/codebase-memory-mcp

# The launcher layer and the plugin it inserts. The patch names the plugin by
# absolute path, so no package manager and no profile install are involved.
COPY proxy.patch.yml /opt/deepseek-harness/proxy.patch.yml
COPY fix/owns-host.mjs /opt/deepseek-harness/fix/owns-host.mjs

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY graphics/runtime.py /usr/local/bin/dsh-graphics
COPY graphics/openbox.xml /opt/deepseek-harness/graphics/openbox.xml

# COPY preserves the source mode, and a restrictive umask produces 0600 files
# that the runtime user (a bare PUID) then cannot read.
RUN chmod 0644 /opt/deepseek-harness/proxy.patch.yml /opt/deepseek-harness/fix/owns-host.mjs \
 && chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/dsh-graphics \
 && chmod 0644 /opt/deepseek-harness/graphics/openbox.xml

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
