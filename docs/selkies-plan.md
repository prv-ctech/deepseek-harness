# Selkies implementation plan

Approved basis: attached 20261003-075456 requirements and in-session approval of Plus-only, opt-in, CPU H.264/WebSockets design. Docker-host acceptance explicitly remains pending when unavailable.

## Goal, architecture and compatibility

Container owns Xvfb, PulseAudio, minimal Openbox and Selkies. Future DSH plugin owns production Chrome; no browser autolaunch, DSH modifications, session orchestrator, publishing or active-deployment changes. Base image and graphics-disabled exec/arguments remain unchanged. Reuse Python 3.11, system Chrome and fonts. One graphics supervisor is necessary because the current entrypoint only execs DSH and cannot monitor several non-root services. No full desktop, vendor drivers, NSS shim or compiler added.

Baseline: clean main at c2f6ba9978095516197b664925f4ee4f2c8005b2, upstream divergence 0/0, one worktree, no staged/unstaged/untracked paths. Required read-set: Dockerfile, docker-entrypoint.sh, compose.yaml, README.md, .github/workflows/build.yml, .dockerignore, .env.example, unraid/deepseek-harness.xml; all read. No CONTEXT/ADR files found. Architecture review required: lifecycle/auth/ownership and redistribution boundary.

Tech stack: pinned native Selkies 2.0.0 Bookworm amd64 .deb (SHA256 fd02cbc08b94eb65f5e834c11849084eec605564d5964f2500dc1209425dc620), Debian Xvfb/Xauth/PulseAudio/Openbox, Python standard library supervisor and unittest checks.

TDD Route: mode off; decision skipped; authority session setting; post-change regression plus isolated container smoke. No strict RED/GREEN obligation.

## Ordered tasks

1. Add graphics/runtime.py, graphics/openbox.xml; wire existing privilege drop to supervisor only when DSH_GRAPHICS_ENABLED=true. Validate configuration/secret; private runtime and Xauth; foreground Unix-only audio; bounded authenticated display/audio/HTTP readiness and actual geometry; monitor services and terminate owned descendants. DSH gets manifest path, not global DISPLAY. Disabled path stays exec dsh. Check with Python standard-library tests, sh -n and argument/UID regression stubs.
2. Add Plus-only checksum-verified native package/prerequisites in Dockerfile; whitelist copied graphics files in .dockerignore. Keep package dependencies (generic graphics ABI libraries are not GPU drivers). Update workflow recipe hash and Plus smoke invocation; no workflow execution/push.
3. Add scripts/graphics-smoke.sh for disposable hardened non-passwd UID/GID container, isolated volumes, no published ports, readiness/auth/Xauth/resize/listener/process/health/shutdown checks. Manual Chrome explicitly requested in this test only. Keep interactive media/CDP/dialog/reconnect/performance checks separate from infrastructure liveness.
4. Update README/config/Unraid and docs/selkies.md with installed paths, environment/manifest, owner boundaries, exact build/run/check/local authenticated viewer access commands, licensing and acceptance matrix. Existing Compose retains disabled default; optional resource knobs only, no new port/capability.
5. Run local checks, independent review, rerun focused checks. Docker build/live media unavailable here (no docker/podman/buildah/nerdctl/socket): record unexecuted checks and measured usage as not measured. No full-completion, release-ready or commit claim on failed/unavailable acceptance. No merge/push/deployment mutation.

## Risks and falsifiers

- Stock Bookworm Xvfb resizing is bounded by initial framebuffer. Start at configured ceiling, resize to initial resolution, verify geometry (selkies-resize can exit zero on failure). If isolated runtime proves stock insufficient, return to design before adding patched build.
- Boolean false/true are client-mutable in Selkies; use false|locked/true|locked for security/CPU/chroma, single H.264 enum, lock off dual mode. Disable microphone/webcam/commands/files/clipboard/gamepads/printing/sharing; preserve same-origin check.
- Numeric UID PulseAudio support is source-grounded, not runtime-proven. Absolute writable HOME and private runtime/config/state; no NSS workaround absent a demonstrated failure.
- GPL-enabled x264/x265/FFmpeg source/notices completeness needs redistribution review. Preserve notices and document exact source inventory; do not claim whole DSH is GPL or redistribution cleared.
- HTTP health is liveness only. Actual decoded media and keyboard/mouse plus CDP same-browser identity require live acceptance, not mocks.

Inline execution; tasks share runtime contract, so serialize implementation. Stop for scope/security/owner drift; retain pending external verification rather than weakening hardening. No existing owner retired; runtime rollback is DSH_GRAPHICS_ENABLED=false.

## User-approved auth amendment

User requested removal of the separate viewer password because access is under Pangolin authentication. This supersedes viewer-secret/Basic-auth portions above: no password file/extra login, explicit locked Basic-auth false, loopback/no published viewer ports unchanged; Xauth and Unix audio authentication stay. Pangolin must cover viewer HTTP/WS route, not merely DSH; automatic embedding/proxy remains future plugin work. Test relay uses host-local stdio forwarding plus SSH, never unauthenticated container-IP listener. Delete obsolete secret configuration/test provisioning (not user files), regress no-password readiness/loopback/override sanitization, and review before authorized main merge/push. Python interpreter/dependency installation is unchanged. TDD mode off; changes reduce lifecycle/config surface. Docker/live-media acceptance and codec redistribution review remain pending.
