# Opt-in Selkies runtime / plugin handoff

**Implementation candidate; Docker/live-media acceptance pending.** No images published, production container restarted, or persistent state volumes deleted during this work. A loopback-only Selkies viewer is available after graphics is enabled, with no separate password. Authentication belongs to Pangolin/proxy (or a test SSH tunnel); DSH embedding/automation is not implemented.

## Image and licenses

Only `INSTALL_PLUS=true` installs graphics dependencies. Base keeps its existing packages/disabled startup. Plus reuses Google Chrome, fonts and Python 3.11, adds Debian Xvfb, Xauth, X11 utilities, PulseAudio, Openbox (window focus/dialogs, no desktop suite) and `ss` for listener checks.

Pinned [Selkies 2.0.0](https://github.com/selkies-project/selkies/releases/tag/2.0.0), source commit `3ec56fb1538cf077c27156f5ab75b6595a83c461`, native `selkies-2.0.0-bookworm-amd64.deb`, SHA256 `fd02cbc08b94eb65f5e834c11849084eec605564d5964f2500dc1209425dc620`. Package version `2.0.0-1~bookworm`; private Python environment uses system Python 3.11. [Exact native documentation](https://github.com/selkies-project/selkies/blob/3ec56fb1538cf077c27156f5ab75b6595a83c461/docs/native.md). No legacy selkies-gstreamer installation, separate frontend build, GPU device/driver, desktop suite or compiler required. Package's generic EGL/GBM/DRM/VA/Wayland ABI dependencies remain installed even in CPU mode.

| Executable/component | Path/version |
| --- | --- |
| Selkies | `/usr/bin/selkies` → `/opt/selkies/bin/selkies`, 2.0.0 |
| Resize helper | `/usr/bin/selkies-resize` → `/opt/selkies/bin/selkies-resize`, same release |
| Python environment | `/opt/selkies/bin/python3` → `/usr/bin/python3`, Debian 3.11 |
| Native extensions | `pixelflux` 2.1.0, `pcmflux` 2.1.0 |
| Bundled viewer | `/opt/selkies/lib/python3.11/site-packages/selkies/selkies_web/` |
| Lifecycle | `/usr/local/bin/dsh-graphics` (image-owned Python helper) |
| X11/auth/check/resize | `/usr/bin/Xvfb`, `/usr/bin/xauth`, `/usr/bin/xdpyinfo`, `/usr/bin/xrandr`, `/usr/bin/xprop` |
| Audio | `/usr/bin/pulseaudio`, `/usr/bin/pactl` |
| Window manager | `/usr/bin/openbox`; image-owned config has focus/move/close/Alt-Tab only, no launch menu |
| Browser | `/usr/bin/google-chrome-stable`, image's existing system Chrome |

Debian/Chrome versions follow image build; record exact versions with `dpkg-query -W selkies xvfb xauth pulseaudio openbox google-chrome-stable python3` in the test container. Build checks package version/hash and native extension imports.

**Redistribution is NOT cleared.** Default native wheels bundle GPL-enabled x264 (`libx264.so.165`), x265 (`libx265.so.216`) and FFmpeg (`libavcodec.so.62`). Selkies is MPL-2.0; GPL obligations apply to combined codec parts, not a blanket relicensing of unrelated DSH code. Preserve notices, provide exact corresponding sources/build scripts for GPL parts, MPL covered sources and bundled frontend, LGPL library source/replaceability and permissive attributions. Codec patent licensing is separate.

Read [pinned Selkies inventory](https://github.com/selkies-project/selkies/blob/3ec56fb1538cf077c27156f5ab75b6595a83c461/docs/licensing.md), [pixelflux 2.1.0 notices/build inventory](https://github.com/selkies-project/pixelflux/blob/2.1.0/LICENSES.md), [pcmflux 2.1.0 inventory](https://github.com/selkies-project/pcmflux/blob/2.1.0/LICENSES.md). Wheels do **not** carry all third-party notices; an inventory link or MPL-only package label is insufficient. Exact bundled library source/notices completeness remains a release blocker. CI builds/tests Plus but fails before push until repository variable `SELKIES_REDISTRIBUTION_REVIEWED=true` is explicitly set after an operator reviews/provides the required artifacts for this exact pin/recipe. Reset that approval when updating Selkies/codecs. This variable records operator approval, not automated legal verification. No workflow was executed here. Building GPL-free pixelflux is deferred; a runtime flag cannot remove bundled GPL code.

## Configuration and writable boundaries

| Variable | Default/constraint |
| --- | --- |
| `DSH_GRAPHICS_ENABLED` | `false`; only literal `true` enables it; invalid values fail startup |
| `DSH_GRAPHICS_DISPLAY` | `:99`; local `:NUMBER`, 0..65535, normalized |
| `DSH_GRAPHICS_RESOLUTION` | `1280x720`; 640x360..3840x2160, width multiple of 8, height even |
| `DSH_GRAPHICS_MAX_RESOLUTION` | `3840x2160`; startup framebuffer ceiling, must contain initial resolution |
| `DSH_GRAPHICS_PORT` | `8080`; internal loopback TCP port, 1024..65535 except 3080; avoid DSH's selected port |
| `DSH_GRAPHICS_ENV_FILE` | Supervisor injects manifest path into DSH only after readiness; plugin reads it, not a shell script |
| `PUID` / `PGID` | Existing privilege drop, including numeric UID/GID absent passwd; graphics rejects UID 0 |

Private `/tmp/dsh-graphics-N/` is created exclusively with mode 0700 under runtime UID. Contains 0600 Xauthority/cookie/config/manifest, private `home`, `config`, `cache`, `state`, `pulse/native` audio socket and optional disabled-feature spool directories. `/tmp/.X11-unix/XN` and `/tmp/.XN-lock` are Xvfb-owned. X11 uses MIT-MAGIC-COOKIE-1 and `-nolisten tcp`; no `-ac` or `xhost +`. Cookie is fed through [`xauth source -`](https://www.x.org/releases/current/doc/man/man1/xauth.1.xhtml), not exposed in process argv. Audio uses authenticated Unix socket only, foreground per-user PulseAudio, null sink `output`/monitor `output.monitor`; no root/system mode, TCP, anonymous access or host audio device. Explicit writable HOME/runtime/state avoids depending on passwd entries; arbitrary-UID runtime still needs live acceptance.

Existing state/workspace volumes retain ownership behavior. Root is used only by existing entrypoint chown/setpriv, never display/audio/WM/streamer. Read-only root, five existing capabilities, `no-new-privileges`, no devices and PID limit 512 remain. Reference Compose preserves its exec-capable `/tmp` default; isolated graphics smoke additionally requires `noexec /tmp`, supported through the existing image-owned native cache redirection. Compose exposes **no graphics/CDP/X11 port**. Keep bridge networking, not host network.

Unraid advanced variables mirror opt-in settings but do not silently replace existing Extra Parameters. For the documented hardened posture, operators can set Extra Parameters on a **separate test container** to `--read-only --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID --security-opt no-new-privileges:true --tmpfs /tmp:rw,nosuid,nodev,noexec,size=512m --shm-size 256m --pids-limit 512 --stop-timeout 20`. Verify kernel/runtime supports each restriction; do not edit/restart active Unraid deployment without approval.

For graphics testing start with `/tmp` 512 MiB, `/dev/shm` 256 MiB, 512 PIDs and 20-second stop grace. Compose knobs: `DSH_TMP_SIZE=512m`, `DSH_SHM_SIZE=256m`, `DSH_PIDS_LIMIT=512`. Defaults remain 256 MiB/64 MiB/512. 3840x2160x24 Xvfb allocates about 32 MiB backing buffer (32-bit storage), independent of smaller active resolution; this is not a whole-container memory estimate. PulseAudio disables shared-memory transport; Chrome smoke uses existing `--disable-dev-shm-usage`. Measure actual workload before changing limits; no FPS/latency guarantees.

## Start, readiness, stop and failure

No password file or additional Selkies login is required. **Every remotely reachable viewer/WS route must pass Pangolin authentication**, not merely DSH's route. Current viewer stays on container loopback and is not automatically exposed through DSH/Pangolin. Future plugin must supply the authenticated same-origin proxy; do not publish/rebind the viewer to bypass that boundary. Old password files may remain unused in existing state; this change does not delete them.

On next *authorized* deployment change set `DSH_GRAPHICS_ENABLED=true` on Plus. With false, entrypoint still directly execs DSH after privilege drop; no display/audio environment is forced, no graphics processes start, existing headless behavior is unchanged.

Enabled path runs `dsh-graphics` under runtime UID: authenticated X handshake → resize and actual geometry → Unix audio/monitor → Openbox ownership → loopback viewer HTTP → manifest → DSH. Readiness probes are timed; failed prerequisites exit nonzero without starting DSH. Later graphics process exit (even status 0) terminates DSH and owned services; no silent restart/fallback. Logs go to container stderr, with `dsh-graphics:` lifecycle markers and native service output. DSH healthcheck remains unchanged; healthy HTTP is **not** proof of decoded media.

Start/stop are entrypoint/container lifecycle, not a new daemon/session API. To inspect in an isolated test:

```sh
docker exec -u 1234:2345 TEST_CONTAINER /usr/local/bin/dsh-graphics --check-graphics
docker logs TEST_CONTAINER
docker stop -t 20 TEST_CONTAINER
```

Supervisor drains DSH while graphics remain available, then terminates service groups, kills/reaps adopted descendants and removes only its exclusively created private runtime. Tini remains PID 1. Duplicate display socket/lock or private directory causes refusal, not takeover. After an abnormal manual supervisor kill, inspect stale ownership/processes before manually cleaning anything; do not delete someone else's display/manifest or blindly restart into it. Container exit destroys test tmpfs; no persistent state directory is removed.

## Future plugin contract

Read JSON at `process.env.DSH_GRAPHICS_ENV_FILE` after DSH starts. Manifest fields: `environment`, `viewer_url`, `websocket_url`, `maximum_resolution`, service `pids`; schema consists of this documented image-owned contract, no credentials in it. `environment` supplies DISPLAY, XAUTHORITY, XDG_RUNTIME_DIR, private HOME/XDG config/cache/state and PULSE variables.

Plugin owns **one** production Chrome instance and its profile/CDP port, launching existing `/usr/bin/google-chrome-stable` **without `--headless`**, with manifest environment merged **only into that browser subprocess**. Keep profile under owned persistent/project state if persistence is needed; manifest HOME is ephemeral. Example launch shape (future plugin pseudocode):

```js
const manifest = JSON.parse(await readFile(process.env.DSH_GRAPHICS_ENV_FILE, 'utf8'));
spawn('/usr/bin/google-chrome-stable', [
  '--ozone-platform=x11', '--no-sandbox', '--disable-dev-shm-usage',
  '--no-first-run', '--no-default-browser-check',
  '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=9222',
  '--user-data-dir=/home/node/.dsh/project-owned-profile'
], { env: { ...process.env, ...manifest.environment } });
```

`--no-sandbox` is existing container Chrome posture, not a newly weakened flag; retain DSH/container confinement. Verify actual CDP listener, not merely the address flag. Plugin must prevent duplicate browser ownership, handle auth/proxy/viewer lifetime, clean its Chrome/profile, and bind CDP internally. Kernel does not isolate different clients sharing one X server; separate project displays/browser ownership belong to later integration, not this single opt-in display. Do not preload gamepad/webcam interposers globally.

Internal viewer `http://127.0.0.1:8080/`, WebSocket `ws://127.0.0.1:8080/api/websockets` (configured port replaces 8080). Selkies Basic auth is explicitly disabled/locked; root/WS/status accept local clients without an extra login. Authentication must cover the viewer HTTP **and** WS at Pangolin/proxy or an SSH tunnel. Untrusted processes in the same network namespace can control the browser; loopback is not an intra-container sandbox. Same-origin WS guard remains; no wildcard origins. HTTP is local only; remote access requires authenticated tunnel/TLS. DSH launch token does **not** authenticate Selkies. Bundled core postMessage controls require same origin; future authenticated same-origin proxy/embedding is plugin work.

Locked CPU H.264/WebSockets, locked 4:2:0, 30 FPS cap (not promised throughput), no transport switch. Mic/webcam/commands/files/clipboard/gamepads/printing/sharing/second screen disabled server-side, not merely hidden UI. Inherited SELKIES/PIXELFLUX/PCMFLUX overrides, pinned legacy aliases (including `VIEWONLY_PASSWORD`/`SUBFOLDER`) and LD_PRELOAD are stripped from graphics children; DSH's original environment is preserved. No WebRTC/STUN/TURN, Docker socket, Docker-in-Docker, GPU or host display required. Viewer grants runtime-UID desktop control; feature toggles are not an application sandbox.

## Repeatable isolated checks (never run against production)

```sh
# Local regressions: mocks + real subprocess teardown, not media acceptance.
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_graphics.py' -v
sh -n docker-entrypoint.sh
bash -n scripts/graphics-smoke.sh

# Run on separate Docker host. Build local tag only; no push/replacement.
docker build --build-arg INSTALL_PLUS=true --build-arg DSH_VERSION=0.2.0-rc.2 \
  -t dsh-plus-selkies:test .
bash scripts/graphics-smoke.sh dsh-plus-selkies:test

# Opt in to keeping its isolated test Chrome/container for interactive checks:
KEEP_GRAPHICS_SMOKE=true bash scripts/graphics-smoke.sh dsh-plus-selkies:test
```

Smoke uses unique test container names, non-passwd UID/GID 1234:2345, read-only root, existing capabilities, no published ports, tmpfs state/workspace (no durable volumes), authenticated X/audio and loopback-only HTTP/WS, wrong-cookie denial, actual resize, listener checks, healthy graphics-disabled DSH, manually launched temporary headed Chrome, CDP `SystemInfo.getProcessInfo` browser PID identity and `Runtime.evaluate` on that same instance, then clean stop and a second fresh graphics runtime killed-audio fail-closed check. Keep mode leaves shutdown/failure checks to operator. No secrets appear on command line. It does **not** prove actual client-decoded streaming, active encoder or user interaction. Default cleanup removes only its created containers, never persistent state volumes. Keep mode transfers test resource cleanup to operator and prints exact container name; stop/remove that named test container when finished.

### Testing an unmerged branch on Unraid

The branch does not create a new image or tag. CI builds on pushes to `main` only
(`.github/workflows/build.yml`), so a branch push publishes nothing, and a manual
run would still stop at the codec redistribution gate before the Plus push.
Build the existing `-plus` variant locally on the Unraid host instead, then add a
**separate** test container — never repoint or restart the active deployment.

```sh
# Unraid terminal, on the array (not /boot). Needs free space in docker.img.
curl -fsSL -o /tmp/dsh.tar.gz \
  https://codeload.github.com/prv-ctech/deepseek-harness/tar.gz/refs/heads/feat/selkies-cpu
mkdir -p /mnt/user/appdata/dsh-selkies-src && tar -xzf /tmp/dsh.tar.gz -C /mnt/user/appdata/dsh-selkies-src --strip-components=1
cd /mnt/user/appdata/dsh-selkies-src
docker build --build-arg INSTALL_PLUS=true --build-arg DSH_VERSION=0.2.0-rc.2 -t dsh-plus-selkies:test .
```

Unraid lists the local image once built, so its Docker UI can create the test
container by name. From the terminal the equivalent hardened run is:

```sh
STATE=/mnt/user/appdata/dsh-selkies-test
mkdir -p "$STATE/workspace"
docker run -d --name dsh-selkies-test --restart no \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID \
  --pids-limit 512 --shm-size 256m --stop-timeout 20 \
  --tmpfs /tmp:rw,nosuid,nodev,size=512m -p 3081:3080 \
  -v "$STATE":/home/node/.dsh -v "$STATE/workspace":/workspace \
  -e PUID=99 -e PGID=100 -e DSH_GRAPHICS_ENABLED=true \
  dsh-plus-selkies:test
docker logs -f dsh-selkies-test   # expect "dsh-graphics: graphics ready", then a dsh pid line
docker exec -u 99:100 dsh-selkies-test /usr/local/bin/dsh-graphics --check-graphics
```

The viewer port stays internal; only DSH's `3080` is published here (host `3081`,
so it cannot collide with the active container). To see pixels, launch the manual
test Chrome on that display and reach the viewer through the relay below:

```sh
docker exec -u 99:100 -e DISPLAY=:99 -e XAUTHORITY=/tmp/dsh-graphics-99/Xauthority \
  -e HOME=/tmp/dsh-graphics-99/home dsh-selkies-test google-chrome-stable \
  --no-sandbox --disable-dev-shm-usage --ozone-platform=x11 \
  --user-data-dir=/tmp/dsh-graphics-99/home/profile https://example.com
```

Finish with `docker rm -f dsh-selkies-test` and remove that test state directory
and `/mnt/user/appdata/dsh-selkies-src` when done. The active deployment, its
image and its state are untouched by this path.

### Authenticated temporary viewer access

Docker port publication cannot reach container loopback. Do not rebind Selkies publicly, and do **not** use the old container-IP relay now that Basic auth is removed. For retained **test** container, operator on Docker host with authorized Docker access and installed `socat` can relay over `docker exec` stdio: both TCP endpoints remain loopback, remote access authenticates through SSH. No Docker socket is mounted inside the container.

```sh
# Docker host: exact isolated test name, never active deployment.
TEST_CONTAINER=dsh-graphics-smoke-REPLACE
# Exclusive temporary file; rerunning refuses to overwrite it.
docker exec -i "$TEST_CONTAINER" sh -c 'umask 077; set -C; cat > /tmp/graphics-test-relay.js' <<'JS'
const socket = require('node:net').connect(8080, '127.0.0.1');
process.stdin.pipe(socket);
socket.pipe(process.stdout);
socket.on('error', () => process.exit(1));
socket.on('close', () => process.exit(0));
JS
# Host-only localhost listener; stop foreground relay after testing.
socat TCP-LISTEN:18081,bind=127.0.0.1,reuseaddr,fork \
  "EXEC:docker exec -i ${TEST_CONTAINER:?} node /tmp/graphics-test-relay.js"

# Viewer machine, another terminal. SSH authenticates operator.
ssh -N -L 127.0.0.1:18080:127.0.0.1:18081 USER@DOCKER_HOST
```

Open `http://localhost:18080/`; no second login. Relay is reachable only on Docker-host localhost, not container IP/LAN. Local host users with loopback access are trusted in this test. Production viewer must instead sit behind Pangolin's authenticated route. SSH forwarding makes browser localhost a secure context for H.264 WebCodecs; test current Chromium first. Firefox/Safari decoder support is not assumed; do not enable 4:4:4 as a workaround. If authorized tunnel tooling is unavailable, report verification blocked rather than exposing production. This relay recipe is documented, not executed here.

### Live acceptance checklist / evidence record

1. Confirm same headed Chrome is visible; click/type into form via **Selkies** (not CDP). Observe changed form via CDP on recorded PID. Move/close/focus window; open/dismiss test alert and verify focus returns.
2. Verify nonblack, changing client-decoded frames, websocket transport, software `x264` active in encoder logs/status/client telemetry, H.264 4:2:0 decoder configuration. Startup flags alone do not prove active encoder. No `/dev/dri`/NVIDIA devices passed. Capture authenticated viewer screenshot plus packet/decoder evidence without credentials.
3. Play a temporary Chrome Web Audio tone via a user gesture; confirm streamed audio, no microphone/webcam prompts. Try crafted disabled-feature controls/requests; locked settings must reject re-enabling. Arbitrary-origin WS denied.
4. Resize 1280x720 → 1920x1080 → 1280x720 (within startup ceiling), compare `xdpyinfo`, active `xrandr` CRTC and decoded dimensions. Keep same Chrome/CDP PID. Stock Xvfb cannot grow above its initial allocation; helper exit 0 alone is insufficient. Disconnect/reconnect authenticated viewer; browser content/PID persists.
5. Record `ss -lntup`, configured UID/GID, read-only/caps/no-new-privileges/PID settings. Only intentional DSH bind may be external; graphics/CDP must be loopback, X11/Pulse Unix-only. Stop the relay/tunnel. Stop test container with 20-second grace; require cleanup marker and no owned host-namespace processes/listeners.
6. Record CPU model/core allocation, RAM limit, image digest, package versions, browser/client version, resolution, 30 FPS cap, idle/form/scroll/video workload, sample duration and `docker stats --no-stream TEST_CONTAINER` samples. Report CPU% and memory with conditions, not universal performance guarantees.

### Current evidence

Local standard-library tests/syntax/diff checks are recorded in final task report. Artifact SHA256/control/native content were inspected; no install/build/live display performed here. **Docker build, hardened graphics runtime, active software encoder, actual streamed pixels/input/audio, same-browser live CDP, resize/dialog/reconnect/shutdown and performance remain unexecuted Docker-host checks. CPU/memory: not measured.** No Docker CLI/daemon socket or alternate container builder available in this environment. Do not interpret source-based compatibility or mocked checks as acceptance completion.
