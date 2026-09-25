# DSH 0.1.7-rc.2 — Docker distribution for Pangolin (research + plan)

Target: upstream `@deepseek-ai/dsh@0.1.7-rc.2`, containerized, reachable at
`https://dsh.example.com/` through Pangolin, with **no localhost/127-only
assumptions** and **no external plugin dependency** (no `dsh-lanmode`).

Hostnames, IP addresses, and local paths in this research record are sanitized
examples; use the deployment's actual values when following it.
Earlier sections retain research-stage recommendations; §7 and the README
describe the shipped image.

Everything below was verified against the real 0.1.7-rc.2 install
(`/tmp/dsh-probe/prefix`, `dsh --version` → `0.1.7-rc.2`), a running patched
server, and default/hardened Docker containers on this host.

---

## 1. Headline: no fork of DSH is required

Every problem is solvable through **supported upstream seams**:

| Problem | Supported seam |
|---|---|
| Bind all interfaces (`--host 0.0.0.0` is CLI-refused) | `--patch` overlay on the `webserver` row (schema accepts `'0.0.0.0'`) |
| Public FQDN rejected by the `/api` fence | `trustedHosts` on the `connection` + `web-runtime` rows |
| Settings pages read-only from a non-loopback URL | `webserver/index-inject` event → `__DSH_TRANSPORT__ {ownsHost:true}` |
| Sandbox unavailable on hosts without kernel sandboxing | Landlock rung (unprivileged, works in hardened containers) + documented escape hatch |
| Container file ownership / PUID-PGID | entrypoint root→`setpriv` |

Patch overlays accept **literal YAML only** — `!!js` tags are rejected there
(`YAMLException: unknown tag !<tag:yaml.org,2002:js>`). Only bundle-provided
patches may use expressions. Therefore the `ownsHost` global needs a real
(tiny) plugin, not a YAML expression.

## 2. Verified facts that drive the design

### 2.1 Binding + trust fence
- `packages/host/webserver/src/index.ts:126-132` accepts exactly
  `'127.0.0.1' | '0.0.0.0'`. `--host 0.0.0.0` is refused at CLI
  (`packages/bundle/web-app/src/startup.ts:74-76`). A `--patch` row restating
  the full config `{host:0.0.0.0, port:3080, compression:gzip,
  compressionLevel:1, compressionThresholdBytes:1024}` binds all interfaces.
  **A patch replaces the whole row config** — restate every owned key.
- Live proof: `ss` after boot → `LISTEN 0 511 0.0.0.0:13080`.
- `isTrustedApiRequest` (`packages/client/connection/src/api-request-trust.ts:91-118`):
  Host required; must be loopback **or** a trusted authority; if `Origin` is
  present it must **strictly equal** `Host`. Single consumer:
  `rpc-host.ts:104-107` → `403` untrusted, `401` unauthenticated.
- Verified live: `GET /` no token → **401**; `Host: evil.example.com` → **403**;
  trusted Host + cookie → passes. **Never rewrite Host to `127.0.0.1:3080`** —
  the browser `Origin: https://dsh.example.com` then fails equality → 403.
- Pangolin's Traefik preserves the inbound Host by default (no `passHostHeader`
  override on resource services; only the maintenance/AI-gateway routes pin it).
  The fence works as long as the site's real Host reaches DSH unchanged.

### 2.2 Auth — launch token → authority-bound cookie
- Launch token: 32 random bytes, memoized per process, **not persisted**.
  `GET /?token=…` → **303** `location: ./` + `Set-Cookie: dsh-auth-<hash>=…`.
- Verified live: `set-cookie: …; Max-Age=2592000; Path=/; HttpOnly;
  SameSite=Strict` — **no `Secure` attribute**, and the signed payload binds
  `"authority":"dsh.example.com"`. The cookie is refused on any other Host.
- HMAC secret persists in `$DSH_HOME/.credentials.yaml`; cookies survive
  restarts, but the *printed URL* rotates every restart.

### 2.3 The "loopback-only Settings" claim in mward4's README is FALSE for 0.1.7-rc.2
- `grep isLoopback` across `packages/api` finds **no server-side gate**.
- `isLoopback` (`packages/client/connection/src/client/index.ts:248`) is a
  **client-side** value through one flag: `ctx.remote.$host.isLoopback`.
- Its complete consumer set: `ui-settings/src/client/index.ts:39`
  (`persistence = isLoopback ? 'host' : 'memory'`) and
  `ui-settings-general/src/client/index.ts:102`. With `memory`, settings
  describe/mutate become no-ops and forms render read-only.
- Live proof over the public Host: `POST /api/settings/describe` →
  `{"writable":true,"hasDocument":true,…}`. A write attempt was refused on a
  **business rule** (`Config field "maxRetries" is not volatile`), i.e. the
  write reached the settings seam — authorization passed.
- Therefore `trustedHosts` alone gives a **readable but not writable** remote
  Settings UI. Injecting `ownsHost:true` restores writability.

### 2.4 The injection seam is first-class (and a ~10-line plugin works)
- `webserver/index-inject` emits `IndexInjection[]`; `{kind:'global', name,
  value}` renders `globalThis[name] = <json>` in `<head>`.
- Official packages already emit global rows (`__DSH_BOOT__`,
  `__DSH_CONNECTION_RECOVERY__`, `__DSH_DOCUMENT_PREVIEW_CONFIG__`, …).
- Plugin = `apply(ctx)` + `main` + `type:"module"`; referenced from a patch
  `insert:` row. An **absolute path** is rewritten to `file://…` beside the
  patch — no pnpm, no npm install needed in the image.
- **Proven end-to-end**: a 4-line plugin made the served page contain
  `globalThis["__DSH_TRANSPORT__"] = {"ownsHost":true}`.
- Risk check: the served page reads only `loadBundle` and `streamBaseUrl` off
  that global (`boot.ts:69`, `ui-settings-account:187`, `stream-client.ts:476`);
  we supply neither, so bundling/streaming are unaffected. The only behavioural
  change is the two settings gates.

### 2.5 Sandbox portability (the user's #1 criticism) — SOLVED by Landlock
- Chain: `PLATFORM_CHAINS.linux = ['bwrap','landlock']`, probed in order.
- In a **default** `node:22-bookworm-slim` container: `bwrap` is absent; even
  when installed, bwrap fails — `Creating new namespace failed: Operation not
  permitted` (Docker's default seccomp/userns policy). So bwrap is not the rung
  to rely on.
- The **Landlock** rung is a prebuilt native binary shipped as an
  optionalDependency (`@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run`).
  Verified enforcing **unprivileged**, with:
  - default container: `/tmp` write OK, `/etc` write denied
  - `--cap-drop ALL --security-opt no-new-privileges --read-only
    --tmpfs /tmp:rw,noexec,nosuid,nodev`: `/tmp` write OK, `/etc` read-only-fs,
    exec from noexec `/tmp` denied
- DSH already fails **closed** when no rung is usable
  (`SANDBOX_UNAVAILABLE`, `sandbox/src/index.ts:132-145`). So the container can
  ship with the sandbox **enabled** rather than disabled — strictly safer than
  both runzhliu (works only where bwrap/kernel allows) and a blanket
  `danger-full-access`.
- Escape hatch for hosts without a usable Landlock: `DSH_PERMISSION_MODE=
  danger-full-access` (also forces approval `never`).

### 2.6 Other confirmed gaps / controls
- **No security headers anywhere in DSH** (no CSP/HSTS/X-Frame-Options/
  X-Content-Type-Options/Referrer-Policy for the GUI). Pangolin's Traefik
  `security-headers` middleware already emits nosniff, `SAMEORIGIN`,
  `referrerPolicy`, HSTS, and strips `Server`/`X-Powered-By`. → proxy-level is
  the cheap and correct answer.
- **No `Secure` on the cookie** (`browser-auth.ts:121-123`) and DSH honours **no**
  `X-Forwarded-*` headers. Mitigations: HSTS at the proxy + TLS-only origin.
  A one-line upstream PR adding `Secure`/honouring `X-Forwarded-Proto` is the
  only clean in-core fix; treat as a separate upstream contribution, not a fork.
- Signals: 5 s drain budget (`process-shutdown.ts`), PID 1 not special-cased →
  use `tini` / `--init`.
- Subpath: DSH 0.1.7 supports serving from a document-relative prefix
  (`<base href="./">`). The user's target is a **root FQDN**, so no prefix
  rewriting is required; only Host preservation.

## 2.7 Three-repo comparison (all verified from clones)

| | **mward4** (`gitea.milesward.dev`, `c398feb`) | **runzhliu** (`github.com/runzhliu/deepseek-harness-docker`, `f907123`) | **lanmode** (`GooDAnDReaDY/dsh-lanmode`, `2bab4a0`) | **ours** |
|---|---|---|---|---|
| Targets 0.1.7-rc.2 | ❌ `0.1.5-rc.2` | ✅ `0.1.7-rc.2-r1` | n/a plugin | ✅ `0.1.7-rc.2` |
| Bind beyond loopback | `web.cordis.patch.yml` → `0.0.0.0` | patch → `0.0.0.0` | bridge-forges Host/Origin | patch → `0.0.0.0` |
| Public FQDN works | partial (`--trusted-host` at runtime) | ✅ opt-in Caddy overlay | ❌ defeats fence | ✅ `trustedHosts` |
| Remote Settings writable | ❌ README says impossible | ❌ (unaddressed) | tries, but inert on 0.1.7 | ✅ `ownsHost` plugin |
| Sandbox on unfriendly hosts | relies on chain, not addressed | keeps `workspace-write`, **no bwrap/landlock fallback addressed** | n/a | ✅ Landlock (verified) |
| Desktop/Chromium stack | no | yes (large surface) | no | no |
| PID 1 reaper | none | tini | n/a | tini |
| Healthcheck | none | yes | n/a | yes |
| Security headers | none | Caddy overlay only | n/a | Pangolin middleware |

Key evidence for runzhliu:
- `web.cordis.patch.yml:3` states **"DeepSeek Harness has no authentication and
  its Web API can execute code"** — **stale for 0.1.7**, which ships launch-token
  + authority-bound HMAC cookie auth (verified live: 401/303/403 behavior).
- README.en.md:340: "do not place this service behind a public Ingress" — i.e.
  it explicitly disclaims the Pangolin topology the user needs. Its `compose.lan.yaml`
  is a **LAN-only** Caddy overlay (`tls internal`, Basic Auth, one exact LAN IP).
- It never mentions Pangolin; its own docs say remote/proxy deployment is out of scope.
- It ships `read_only: true`, `cap_drop: ALL`, `no-new-privileges`,
  `tmpfs /tmp:noexec` and sets `NARB_DISABLE_NATIVE_CACHE=1` for the noexec
  native-addon cache — good hardening we reuse; but it pairs that with
  `workspace-write` sandbox and **no statement that Landlock rescues hosts
  where bwrap cannot run** (verified: bwrap fails in a default container).

Conclusion: neither reference repo delivers the requested outcome. mward4 is
the best *build/packaging* baseline (pin, PUID/PGID, regctl) but is a release
behind; runzhliu is the best *hardening* baseline but is LAN-only by design;
lanmode is unnecessary and its security mechanisms are inert/unsafe on 0.1.7.

## 3. Proposed deliverable

A small repo (in the working directory — currently a read-only mount, so
staged under `/tmp` until a writable location is confirmed) containing:

```
Dockerfile                 # node:22-bookworm-slim + dsh@0.1.7-rc.2 + tini
docker-entrypoint.sh       # PUID/PGID chown → setpriv → dsh
proxy.patch.yml            # webserver 0.0.0.0 / connection+web-runtime trustedHosts / plugin insert
fix/                       # the ~10-line ownsHost injection plugin (file:// referenced)
docker-compose.yml         # single service, volume, healthcheck
README.md                  # Pangolin wiring + security caveats
```

Design decisions:

1. **Pin the exact release.** `npm i -g @deepseek-ai/dsh@0.1.7-rc.2` (verified
   installable; `bin.dsh = lib/bin.js`, 81 runtime deps, no source build).
   Pin base image by digest.
2. **Bind `0.0.0.0` inside the container** via the patch overlay; recommend the
   compose file publish to `127.0.0.1:3080` on the host and point Pangolin at
   that, or target the container IP directly.
3. **`trustedHosts: ['dsh.example.com']`** (configurable via env so the FQDN
   is not hardcoded).
4. **Ship the `ownsHost` plugin** so remote Settings is fully writable — the one
   thing `trustedHosts` alone does not fix.
5. **Keep the sandbox on.** Default `workspace-write`. Document
   `DSH_PERMISSION_MODE=danger-full-access` for hosts where Landlock is
   unavailable.
6. **`tini` as PID 1**, plus a `HEALTHCHECK` hitting `/` and accepting
   `200/303/401` (all three mean "DSH is answering").
7. **PUID/PGID entrypoint** reusing mward4's proven ownership pattern: recursive
   chown of `$DSH_HOME` only when needed, `/workspace` mount point only,
   recursion opt-in.
8. **Do not ship** runzhliu's Chromium/noVNC desktop stack — large attack
   surface, not needed for the web GUI use case.
9. **Proxy-side security headers** — but NOT by reusing Pangolin's shipped
   `security-headers` middleware. That middleware exists only in
   `install/config/crowdsec/dynamic_config.yml` and is attached to the
   dashboard's own routers (`:79,:91,:103`), not to user resources. The operator
   needs their own Traefik middleware. Traefik's `customResponseHeaders` sets
   static values only, so runzhliu's Caddy `header >Set-Cookie (.*) "$1; Secure"`
   trick is not portable; HSTS (which Pangolin's setup does enable) is what keeps
   the `Secure`-less cookie off plaintext requests.

## 4. Explicitly out of scope (and why)

- Forking or patching DSH source — unnecessary; every change is a config layer
  plus one tiny plugin.
- Installing `dsh-lanmode` — its loopback-unlock is dead code on 0.1.7 (string
  no longer matches), its privileged-path matches use dots vs the real
  slash-separated wire form, and it **forges Host/Origin** to defeat the fence.
- Subpath deployment — the target is a root FQDN; DSH supports prefixes but the
  proxy contract (strip prefix, rewrite cookie `Path`) is extra work with no
  current need.

## 5. Verification plan (what "done" means)

- `docker build` succeeds; `docker run` boots and logs the
  `dsh web: …/?token=…` line.
- `curl` with the public Host: `/` → 401, `/?token=…` → 303 + cookie,
  `/api/settings/describe` → `writable:true`, untrusted Host → 403.
- Served index contains `__DSH_TRANSPORT__ = {"ownsHost":true}`.
- A confined command runs and a write outside the workspace is denied
  (non-root, no capability additions, no `--privileged`).
- Healthcheck reports healthy; `docker stop` exits cleanly within the drain
  budget.

All six were exercised; the results, in order:

| # | Check | Result |
|---|---|---|
| 1 | `docker run` boots and logs the token URL | pass (`dsh web: …/?token=…`) |
| 2 | Fence: `/` 401, `/?token=…` 303 + cookie, `settings/describe` 200 `writable:true`, untrusted Host 403 | pass |
| 3 | Index carries `__DSH_TRANSPORT__ {ownsHost:true}` | pass (34372-byte index) |
| 4 | Confined command runs; outside writes denied | pass — see below |
| 5 | Healthcheck healthy | pass |
| 6 | `docker stop` exits cleanly | pass (exit 0, immediate, no SIGKILL) |

Check 4 detail, run inside the hardened container (`--read-only`, `--cap-drop
ALL` + five re-added caps, `no-new-privileges`, `noexec /tmp`) as the
unprivileged dsh uid via the real launcher API
(`launcherPath`/`grantArgs`), i.e. the same path dsh uses:
`probe()` → **`full`** (the authoritative availability signal, not a
`--version` check); write inside `/workspace` → **succeeds**; write to `/etc`,
`/root` and the state dir `/home/node/.dsh` → **denied** with
`Read-only file system` / `Permission denied`; reading `/etc/passwd` still
allowed.

Two caveats worth recording, both upstream facts rather than defects in this
distribution:

- **Landlock is filesystem-only.** `landlockProfileArgs`
  (`dsh-sandbox-local/lib/index.js:45-53`) grants `readOnly: ["/"]` plus
  `readWrite: ["/dev/null", "/tmp", workspaceRoot]` and nothing else — there is
  no network rule, and an outbound `fetch` from inside the confinement
  succeeded. The sandbox bounds file effects, not egress.
- **`--read-only` alone is not a confinement test.** The first attempt showed
  the workspace write failing, which looked like over-restriction; it was the
  test's own fault — no workspace volume was mounted, so `/workspace` was the
  image's read-only directory. A workspace mount is required for
  `workspace-write` to mean anything.

## 6. Decisions taken (answers to the original open questions)

1. **Topology** — Pangolin runs on an external VPS; `newt` sits on the private
   Docker network and targets the site at `http://192.168.1.10:3080`. The
   container therefore publishes `0.0.0.0:3080:3080` on the host (any
   non-loopback interface; a `127.0.0.1` publish is invisible to `newt`), and
   DSH binds `0.0.0.0` inside the container. Pangolin preserves the inbound
   `Host` by default, which the `/api` fence depends on.
2. **FQDN** — configurable via `DSH_PUBLIC_HOST`; the image has no default.
   Compose requires a value, while the Unraid template leaves it optional for
   access by IP. The entrypoint passes a configured value as `--trusted-host`;
   `DSH_TRUSTED_HOSTS` adds extra authorities.
3. **Sandbox** — stays **on** (`workspace-write`). Landlock is the rung that
   works in a container; `danger-full-access` is documented as the escape hatch.
4. **Location** — a local checkout (the Samba mount could not host the edit
   tools: `ENOTTY` on their temp-dir chmod).

## 7. Implementation status

Implemented and verified on this host. Two findings changed the design beyond
the original plan:

- **A patch layer replaces the row's whole config.** A host-only patch boots to
  `ValidationError: invalid config: $.port missing required value`, so
  `proxy.patch.yml` restates all five webserver keys.
- **The native-addon cache breaks `noexec /tmp`.** dsh's loader copies each
  prebuilt `.node` into `os.tmpdir()` and `dlopen`s it there, so a hardened
  `--tmpfs /tmp:noexec` container dies with `Cannot find module
  …/napi-v9-linux-x64-gnu/require_builtin.node`. The image sets
  `NARB_NATIVE_CACHE_DIR` into the state volume, which is what makes
  `--read-only` + `noexec /tmp` usable.
- Also verified: the entrypoint needs `setpriv --clear-groups`, not
  `--init-groups` (the latter rejects a uid with no passwd entry, e.g. Unraid's
  `99:100`), and dsh runs fine as such a uid given `HOME`/`SHELL`/`DSH_HOME`.

### 7.1 Unraid distribution and CI release tracking

`unraid/deepseek-harness.xml` is our own template: the `templates-user` XML
convention as a format reference, every value ours. Verified by starting a real
container with exactly the template's defaults (`PUID=99`, `PGID=100`, no
`DSH_PUBLIC_HOST`): appdata and workspace ended up owned `99:100`, health
`healthy`, browsing by container IP passed the `/api` fence (401 = trusted,
awaiting cookie) while an undeclared hostname got 403. The full login flow was
then exercised inside the container — `/?token=…` → 303 + cookie,
`settings/describe` → 200 with `writable:true`, index → 200 containing
`__DSH_TRANSPORT__ {ownsHost:true}`.

Two bugs surfaced while building it, both invisible until a real Unraid-style
invocation was tried:

- **Caller-supplied web flags were rejected.** The entrypoint unconditionally
  injected `--patch`/`--no-open`, so Post Arguments holding
  `web --patch … --no-open` (the pattern the reference repo documents) produced
  `error: unknown option '--patch'` and the container exited. Cause: `--patch`
  is launcher-owned and must precede the first app-owned flag, whereas
  `--no-open` and `--trusted-host` are app-owned. The entrypoint now lets the
  caller's flags win and injects only what is absent; four call styles verified
  (no args, bare flags, mward4-style PostArgs, `web --no-open`).
- **`scripts/published-recipe.sh` could not read a private package.** It
  presented a GitHub token as a raw registry Bearer, which ghcr answers with
  403; the token must be exchanged at the token endpoint via Basic auth
  (verified: raw → 403, exchanged → 200). Unfixed, the plan job would have read
  every published tag as missing and rebuilt all of them every six hours. An
  unbound `$token` under `set -u` on the plain-HTTP path was fixed with it.

**CI package-name collision.** Pushing to `ghcr.io/prv-ctech/deepseek-harness`
was denied with `permission_denied: write_package` while a fresh package name
succeeded from the same run, so it is a package-ownership collision rather than
a workflow bug: that package already exists (holding a 3.67GB image built by a
different project from `@deepseek-ai/dsh@0.1.6-alpha.1`, mislabelled with this
repository's URL), and GHCR grants write access at the package level. The
repository's Actions `packages: write` permission alone does not grant access to
this existing package. GitHub documents **Package settings → Manage Actions
access → Add repository → Write** for this case.

On 2026-09-25, the operator reported removing the package, but a fresh
workflow dispatch ([run 36106183963](https://github.com/prv-ctech/deepseek-harness/actions/runs/36106183963))
still failed at the push with the same error. A fresh GHCR manifest request
still served the old `:latest` digest
`sha256:9f8f4b442f32c60a5f64fa1e5a2a1674fec71dc24c3b85c1fdb7c1bd3a7f6430`;
`0.1.7-rc.2` was absent at that time. The deletion later propagated: a second
dispatch ([run 36106958983](https://github.com/prv-ctech/deepseek-harness/actions/runs/36106958983))
passed planning, pushed `0.1.7-rc.2`, pulled it for the container smoke test
(healthy, DSH UID 1000, index 401 without login), and copied its manifest to
`:latest`. The new package is private (anonymous GHCR pull-token request returned
401). The operator chose registry login for Unraid rather than public access.
Pullers need a GitHub personal access token (classic) with `read:packages` and
account access to the package; credentials stay on the Docker host, outside the
template. The available CLI token lacks `read:packages`, so this task did not
independently pull the private image from Unraid.

Local recheck on 2026-09-25: the `0.1.7-rc.2` image built, and all four
supported entrypoint forms (default, bare app flags, `web --patch … --no-open`,
and `web --no-open`) reached a healthy server as UID `99` and printed the public
URL. The authenticated HTTP flow returned `/api/settings/describe` 401 without
a cookie, 403 for an untrusted Host, then 200 with `writable:true` after the
launch-token exchange (303); the served page included `ownsHost:true`. A
proposed uncommitted entrypoint change for `--patch FILE web` was discarded:
upstream DSH itself rejects that argument order with `--profile <name> is
required`. The supported order is `web --patch FILE`.
