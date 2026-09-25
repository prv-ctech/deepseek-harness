# runzhliu/deepseek-harness-docker — audit for our Pangolin deployment

Clone: `github.com/runzhliu/deepseek-harness-docker` @
`f907123ec5f17dd0ce4a1579dca1569e7fc96365` (2026-09-25).
Note: the repo `runzhliu/deepseek-harness` does **not** exist on GitHub; this
Docker repo is the real artifact. Docker Hub image: `runzhliu/deepseek-harness`.

Inspected directly from the clone (read-only). This doc was produced by inline
inspection rather than by the delegated subagent, which did not complete.

## 1. Build

- `Dockerfile`: multi-stage; `ARG NODE_IMAGE=docker.io/library/node:24-trixie`,
  `ARG DSH_VERSION=0.1.7-rc.2`, `ARG PNPM_VERSION=10.15.1`.
- Installer stage adds `build-essential`, `ca-certificates`, `python3`, then
  `npm install --global --omit=dev --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs`.
  The `--allow-scripts` list is required because npm 11+ blocks lifecycle
  scripts by default and those packages have native postinstall builds.
- Verifies the install by exact equality:
  `test "$(dsh --version)" = "${DSH_VERSION}"`.
- Installs `@deepseek-ai/dsh-browser-use` into a **separate prefix**
  (`/opt/dsh-browser-use`) and merges later, because installing extra packages
  into the published DSH tree can make npm prune DSH's own generated
  distribution. Good, reusable lesson.
- Ships a Chromium + noVNC desktop stack (`scripts/chromium-docker` runs
  chromium with `--no-sandbox`).

## 2. Reverse-proxy posture — explicitly LAN-only

- `compose.yaml` publishes **loopback only**: `127.0.0.1:${DSH_PORT:-3080}:3080`
  and `127.0.0.1:${DSH_DESKTOP_PORT:-6080}:6080`.
- `web.cordis.patch.yml:3` carries the comment:
  *"DeepSeek Harness has no authentication and its Web API can execute code."*
  **This is stale for 0.1.7.** 0.1.7 ships a launch token plus an
  authority-bound HMAC cookie (verified live: `401` unauthenticated, `303` +
  `Set-Cookie` on token exchange, `403` on untrusted Host). The comment reflects
  the 0.1.5-era model.
- `README.en.md:340` states: *"do not place this service behind a public
  Ingress: Web has no TLS, and noVNC on 6080 has no authentication."*
- `compose.lan.yaml` is the **only** remote-access path and is LAN-scoped:
  Caddy with `tls internal` (self-signed internal CA that must be installed on
  every client), HTTP Basic Auth, bound to one explicit LAN IP
  (`${DSH_LAN_BIND_ADDRESS}:${DSH_LAN_HTTPS_PORT:-8443}:8443`), and
  `--trusted-host ${DSH_LAN_HOST}` passed through compose `command`.
- **Pangolin is never mentioned anywhere in the repo.** It does not claim, and
  does not support, the topology this project targets.

## 3. The one genuinely useful idea: cookie `Secure` at the proxy

`config/Caddyfile.lan`:

```
header >Set-Cookie (.*) "$1; Secure"
header {
    Strict-Transport-Security "max-age=31536000"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "no-referrer"
}
```

This confirms two things:

1. DSH's cookie genuinely lacks `Secure` (they patched it at the proxy).
2. Adding `Secure` is possible **if** the proxy supports response-header
   rewriting.

Caveat for our target: Caddy supports regex response-header rewriting;
**Pangolin's Traefik middleware does not** (`customResponseHeaders` sets static
values only). So this exact trick is not portable to Pangolin. Our mitigation is
proxy-side HSTS — Pangolin's shipped `security-headers` middleware sets
`forceSTSHeader: true`, `stsSeconds: 63072000`, `stsIncludeSubdomains: true`,
`stsPreload: true`, which forces the browser to HTTPS for the whole domain and
therefore prevents any plaintext request that could leak the cookie.

## 4. Hardening we reuse

`compose.yaml`:

- `read_only: true`
- `tmpfs: /tmp:rw,noexec,nosuid,nodev,size=512m`
- `cap_drop: [ALL]`
- `security_opt: [no-new-privileges:true]`
- `pids_limit: 512`
- `healthcheck` asserting `web.status === 401` **and** desktop + CDP endpoints
- `NARB_DISABLE_NATIVE_CACHE=1` (via `scripts/dsh-container`) so 0.1.7's native
  addon cache does not try to exec from the `noexec` `/tmp`
- `--allow-scripts=...` for native postinstalls
- image build verified by exact version equality

## 5. Sandbox posture — unaddressed gap

- No `sandbox-policy`, `permission`, or `approval` rows are patched anywhere
  (`web.cordis.patch.yml`, `web.market.cordis.patch.yml`): it relies on the
  shipped default `workspace-write`.
- Nothing in the repo addresses hosts where the Linux runner chain cannot work.
  Verified independently: in a **default** `node:22-bookworm-slim` container
  `bwrap` is absent, and even when installed it fails with
  `Creating new namespace failed: Operation not permitted` under Docker's
  default seccomp/userns policy. DSH's chain is `['bwrap','landlock']`, so such
  a host falls through to Landlock — which we verified **does** enforce
  (unprivileged, and even under `cap_drop ALL` + `no-new-privileges` +
  read-only rootfs). runzhliu neither relies on this nor says what happens when
  neither rung works (DSH fails closed with `SANDBOX_UNAVAILABLE`).

## 6. Classification

**Reuse:**

- Keep-only-that-capability insight in the LAN Caddy overlay
  (`cap_add: NET_BIND_SERVICE` alongside `cap_drop: ALL`).
- `NARB_DISABLE_NATIVE_CACHE=1` for noexec `/tmp`.
- `--allow-scripts=` list for native postinstalls.
- `read_only` + `cap_drop ALL` + `no-new-privileges` + `pids_limit` compose shape.
- Healthcheck that asserts a **specific** status code, not just `ok`.
- Version-equality assertion at build time.
- Separate npm prefix for extra packages.

**Do not reuse:**

- Chromium/noVNC desktop stack — large attack surface, unrelated to the web-GUI
  goal, and its `--no-sandbox` flag is the opposite of what we want.
- LAN-only Caddy overlay — Pangolin is the TLS/auth boundary in our topology.
- The stale "no authentication" premise in `web.cordis.patch.yml`.

## 7. Verdict

runzhliu is the strongest **hardening** reference of the three, and the weakest
**topology** reference: it is deliberately loopback/LAN-only, disclaims public
ingress in its own README, and never addresses Pangolin. Its `--trusted-host`
usage is real and correct, but only in service of a LAN Caddy gateway.
