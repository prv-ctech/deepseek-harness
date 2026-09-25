# Security & Compatibility Audit — `@goodandready/dsh-lanmode` v0.8.5

Historical source audit. The shipped image uses the verified recipe in the
repository README and `docs/PLAN.md` §7; some recommendations below were
revised after live testing.

- **Audited repo:** `/tmp/dsh-research/lanmode` (== `github.com/GooDAnDReaDY/dsh-lanmode`), MIT.
- **Commit:** `2bab4a068daf4b5207fece5a34e95d6e3edb4e17` (main), package `@goodandready/dsh-lanmode` v0.8.5.
- **Reference platform:** official DSH `0.1.7-rc.2` at `/tmp/dsh-research/official` (git HEAD `477b4f420553e8a52c2fbccc464d7561b239c443`, merge PR #5180).
- **Our target:** container + config for DSH 0.1.7-rc.2 behind an external TLS-terminating reverse proxy (Pangolin) at `https://dsh.example.com/` (sanitized example hostname).
- **Method:** read-only source audit. No edits, no installs, no services run in the audited repo. Every claim carries `path:line`; anything not confirmed in source is marked **UNVERIFIED**.
- **Size:** ~11,300 JS lines under `lib/` (plus ~2,736 lines of injected client JS in `lib/client-parts/`, and shell/HTML in `lib/login-page.js` 458 / `lib/qr.js` 469). No regression-test directory ships in the published package (`package.json` `test` script points at `test/*.test.mjs`, but `files` is `["lib/","cordis.patch.yml","README*.md","LICENSE"]`).

> **Correction to the brief.** The task premise ("DSH 0.1.7 ... exposes a supported `webserver/index-inject` seam that can set `globalThis.__DSH_TRANSPORT__ = { ownsHost: true }` for served pages, which flips the client-side isLoopback gate") is **only half true**. The seam is real and the injection mechanism is real, but upstream explicitly documents that **served pages never carry `__DSH_TRANSPORT__`** — it is a desktop-shell / worker-runtime construct. See §2 and §10.

---

## 0. Executive summary

lanmode is a serious, well-argued LAN-access enabler built for the *no-reverse-proxy* case. For our case (external TLS at a public FQDN) **almost none of it is needed**, and several parts are actively dangerous to copy.

The three findings that matter most:

1. **The loopback "unlock" is dead code on 0.1.7-rc.2.** Its text-replace target string no longer exists (source *or* compiled bundle). It silently no-ops. The behaviour is instead achieved by the injected shim setting the supported `__DSH_TRANSPORT__.ownsHost = true` global — which upstream documents as *not* intended for served pages.
2. **lanmode defeats upstream's Host/Origin trust fence by forging `host` and `origin` to `http://127.0.0.1:<port>` on every proxied request** (`lib/bridge-utils.js:20-30`). That is a deliberate confused-deputy: upstream's fence compares the request's Origin to the request's Host, so rewriting *both* passes it. We must never do this; the supported alternative is `trustedHosts`.
3. **`unlockPrivileged` defaults to `true`** (`lib/config-schema.js:94-97`) and, when no LAN PIN is set, privileged settings/credentials endpoints are simply **open to any allowlisted remote client**. Combined with (2) that is the single most dangerous default — but the *shipped* default also sets `allow: ['127.0.0.0/8']` and `directHost: '127.0.0.1'`, so the stock install is inert until the operator widens both. The danger materialises the moment an operator follows the README example (`directHost: 0.0.0.0`, `allow: [192.168.0.0/16]`) and leaves `unlockPrivileged` at its default.

**Verdict:** borrow the *ideas* (inject via `webserver/index-inject`, polyfills for non-secure context, PWA/meta, a per-device session viewer) and the *failure posture* (fail-closed allow-list). Copy **none** of the bridge, the header forging, the loopback rewrite, the in-app updater, or the forced-unlock default. Behind Pangolin, TLS/mDNS/Root-CA/SNI/Cloudflare-tunnel/firewall/compression are all things the proxy (or the platform) owns.

---

## 1. Integration: how it mounts and how it changes the page

### 1.1 Bundle patch row

`cordis.patch.yml` (30 lines) is the `dsh.bundle.patch` for the profile. It `insert`s a row:

- `id: dsh-lanmode`, `name: '@goodandready/dsh-lanmode'`
- default config: `{ mode: auto, directHost: '127.0.0.1', directPort: 3088, allow: ['127.0.0.0/8'] }` (`cordis.patch.yml:24-29`)
- A comment (`cordis.patch.yml:9-11`) states that since DSH 0.1.7+ configuration lives in the profile row's `config:` section because the old `settings.register` API was removed.

`package.json` declares `dsh.bundle.patch = ./cordis.patch.yml` and `dsh.client = { platform: 'web', inject: ['@deepseek-ai/dsh-client-locale', '@deepseek-ai/dsh-client-ui-slots'] }`.

### 1.2 Host plugin surface consumed

`lib/index.js`:
- `export const inject = ['webServer']` (`lib/index.js:49`) — so it depends on the `webServer` service (`packages/host/webserver/src/index.ts:145` `super(ctx, 'webServer')`). ✔ matches 0.1.7-rc.2.
- Also reads, defensively, `ctx.get('connection')` / `ctx.connection` for `authenticatedUrl()` (`lib/index.js:430-433`).

Host APIs actually used:
| API | Where | Matches 0.1.7-rc.2? |
|---|---|---|
| `ctx.webServer.tapIndex(fn)` | `lib/index.js:550-557` | ✔ `packages/host/webserver/src/index.ts:212-218`, returns disposer |
| `ctx.webServer.register({kind,path,handler})` | `lib/routes/*`, `lib/index.js:466-527`, `lib/pwa-manifest.js`, `lib/plugin-updater.js` | ✔ `WebRoute{kind:'exact'\|'prefix',path,handler}` at `packages/host/webserver/src/index.ts:42-53`, `register()` at `:166` |
| `ctx.get('connection').authenticatedUrl(base)` | `lib/index.js:431-432` | ✔ `packages/client/connection/src/rpc-host.ts:121-123` |
| `ctx.effect(fn, label)` | throughout | ✔ cordis |

It does **not** consume `webserver/index-inject` (the structured row event); it uses the raw-string `tapIndex` escape hatch. `tapIndex` runs **after** structured rows (`packages/host/webserver/src/index.ts:362`).

The package `dsh.client.inject` names two client packages; the compiled client entry `lib/client.js` calls `window.__ModuleLoader__.load({ id: '@goodandready/dsh-lanmode', factory })` (22 lines) and fails loudly if `window.__DSH_LANMODE_PARTS` is missing (`lib/client.js:10-12`).

### 1.3 Page injection order (exact)

`lib/index.js:550-557` registers a `tapIndex` transform:
```js
if (html.includes('data-dsh-lanmode')) return html          // idempotence, :551
const insert = clientPartsScript() + pwaMeta(...) + mobileStyles() + script() + navScript()
// spliced immediately after the first <head...> match; prepended if no <head>  :553-556
```
`script()` (`lib/index.js:541-544`) emits, **inline in `<head>` and therefore before any bundle**:
```html
<script data-dsh-lanmode="1">
window.__DSH_LANMODE__={...};
/* full shim.js source */
</script>
```
`clientPartsScript()` (`lib/index.js:58-63`) reads every `lib/client-parts/*.js` in sorted order, concatenates, and wraps in `<script data-dsh-lanmode-parts="1">`, escaping `</script` → `<\/script`.
`navScript()` (`lib/index.js:546-548`) emits `<script data-dsh-lanmode-nav="1">` + `mobileNavSource()`.
`pwaMeta()` (`lib/index.js:531-539`) adds `viewport-fit=cover`, `apple-mobile-web-app-capable`, `mobile-web-app-capable`, `status-bar-style`, `theme-color #1e1e2e`, `apple-touch-icon /favicon.ico`, and `<link rel=manifest href=/dsh-lanmode/manifest.json>`.

`window.__DSH_LANMODE__` carries `{settings, randomUuid, clipboard, mobileEnterSends, passwordAuth, authUser, publicHost}` (`lib/index.js:271-279`).

### 1.4 Runtime module-loader patching (this is the invasive part)

`lib/shim.js:284-329` hijacks `window.__ModuleLoader__`: it defines an accessor property `load` whose **setter re-wraps**, and rewrites entries already queued in `loader.pendingQueue` (`lib/shim.js:308-312`). For every plugin registration it patches `registration.factory` and replaces the module export's `apply` with a `Proxy` (`lib/shim.js:246-279`) that calls `forceOnConnection(args[0])` before delegating. `forceOnConnection` does `Object.defineProperty(connection, 'isLoopback', { configurable: true, get: () => loopbackAnswer })` (`lib/shim.js:202-216`). A single package — `@deepseek-ai/dsh-client-ui-deliverables` (`lib/shim.js:187-189`) — is excluded and instead receives a proxy that restores the *real* loopback flag.

**Assessment:** this monkey-patches the loader and every plugin's `apply` inside a *served* page. It is the least durable part of the client side and the most likely to break on any client-runtime refactor.

### 1.5 Host event / tool surface

- `registerMobileQrTool(ctx, state)` (`lib/index.js:460`) registers the `/mobileqr` tool.
- Host-side session events are **not** consumed: the only `turn/end` / `approval/asked` listeners live in the *client* card (`lib/client-parts/09-apply.js:187-200`) via the client cordis `ctx.on`.
- `lib/index.js:423-457` self-checks its mounting assumptions after 3 s and logs `MOUNTING POINTS DRIFTED (...)`. This is an explicit admission that the internals it depends on may drift.

---

## 2. The loopback "unlock": the brittle rewrite vs the supported global

### 2.1 The exact strings it text-replaces

`lib/loopback-source.js` (33 lines):
- `CONNECTION_BUNDLE = '/plugins/@deepseek-ai/dsh-client-connection/client.js'` (`:11`)
- `COMPUTED = 'isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),'` (`:13`)
- `ALWAYS = 'isLoopback: true,'` (`:15`)
- `forceLoopback(source)` (`:29-33`): if the literal `COMPUTED` is absent → `{changed:false}`; else `.replace(COMPUTED, ALWAYS)`.
- `isConnectionBundle(url)` (`:18-21`) matches the path exactly (query stripped).

`lib/bridge.js:407-419` buffers the whole response body for that one path and runs `forceLoopback`; when unchanged it logs the notice at `lib/bridge.js:411` ("DeepSeek Harness core now operates self-sufficiently; loopback rewrites preserved for compatibility").

### 2.2 It does not match 0.1.7-rc.2 — VERIFIED, including the compiled bundle

Upstream **source** `packages/client/connection/src/client/index.ts:248`:
```ts
isLoopback: transport?.ownsHost === true || pageLocation === undefined || isLoopbackHostname(pageLocation.hostname),
```
Two mismatches vs `COMPUTED`: (a) a leading `transport?.ownsHost === true || `; (b) `=== undefined` where the plugin expects `=== void 0`.

Repo-wide grep for the plugin's literal → **zero hits** in TS source.

**Compiled artifact — previously UNVERIFIED, now VERIFIED negative via the locally installed package:**
- A local DSH install's `node_modules/@deepseek-ai/dsh-client-connection/lib/client.js` (221,770 bytes) contains
  `isLoopback: transport?.ownsHost === true || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),`
- `grep -F 'isLoopback: pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),'` → **0 matches**.
- A local `0.1.7-alpha.1` desktop bundle's `node_modules/.pnpm/@deepseek-ai+dsh-client-connection@0.1.7-alpha.1_.../lib/client.js` shows the identical expression.

So the transpiled form *does* normalise `undefined → void 0`, but the leading `transport?.ownsHost === true || ` clause makes the plugin's literal unmatchable. **`forceLoopback` is a permanent no-op from ~0.1.7 onward.** (The only residual uncertainty is the exact future-minor bundle text, which by the plugin's own admission may drift; the *mechanism* is unsound regardless.)

### 2.3 Why the rewrite is brittle by construction

It is an exact-substring text replacement against a **minified third-party client bundle** whose content is an output of an upstream build, guarded only by a substring `includes` test. There is no version check, no AST, no fallback that fails loudly. On mismatch it returns `changed:false` and the operator sees only a log line. Any upstream edit to that expression — a reordered clause, a rename, a formatter change, a minifier change — silently disables the feature. This is the canonical "patched private build output" anti-pattern.

### 2.4 Does the plugin *also* set `__DSH_TRANSPORT__`? — YES

`lib/shim.js:15-19`:
```js
// #178: remote clients that loaded this shim are the host owner for UI gates.
try {
  var transport = window.__DSH_TRANSPORT__ || (window.__DSH_TRANSPORT__ = {})
  if (loopbackAnswer) transport.ownsHost = true
} catch (err) { /* bestEffort */ void err }
```
So lanmode relies on **both**: the (dead) bundle rewrite *and* the supported global. Because it sets the global, the client-side effect still lands even though the rewrite no-ops. Additionally `lib/client-parts/09-apply.js:14-16` does `ctx.connection.isLoopback = true` on its own card's `ctx`.

### 2.5 Contrast with the supported seam

The **intended** upstream mechanism for a served page is *not* `__DSH_TRANSPORT__`. Upstream documentation at `packages/client/connection/src/client/index.ts:96-104`:
> "The transport owner declares the page owns the Host outright: the Host runs inside a worker this page spawned… Only a shell that assembles its own transport can set this; **served pages never carry the global at all**."

Corroborated by tests asserting `'__DSH_TRANSPORT__' in globalThis === false` for the served app (`packages/test-support/client-runtime/tests/assembly-vitest.client.spec.ts:20,49,63`).

The genuinely supported mechanisms are:
1. **`webserver/index-inject`** — declared `packages/host/webserver/src/index.ts:34`, emitted at `:350`, row union at `packages/host/webserver/src/injections.ts:15-31` (`global|script|script-src|script-preload|style|html`, placement head/body). A `{kind:'global', name:'__DSH_TRANSPORT__', value:{ownsHost:true}}` row is *technically* valid and lands in head, but it uses a global upstream says served pages should not carry.
2. **`trustedHosts`** (`packages/client/connection/src/index.ts:103,110-115`) — the *authored* way to let a real public authority through the Host/Origin fence without forging anything. This is the correct lever for Pangolin.
3. **`tapIndex`** — the raw HTML escape hatch, appropriate for innocuous markup (meta tags, styles) but not for re-deriving security-relevant page state.

**Conclusion:** for our design, do **not** inject `ownsHost`. Serve the page at the real FQDN and (if needed) set `trustedHosts: ['dsh.example.com']`. If we ever need the privileged UI reachable from the browser, that is exactly what `trustedHosts` + DSH's own browser auth already permit; forcing `ownsHost` is redundant and diverges from the documented model.

---

## 3. Privileged API surface

### 3.1 What the plugin calls "privileged"

`lib/privileged.js:15-21` — regex list matched against the path (query stripped, `:29-41`):
```
^/api/settings\.(describe|openDocument|update|replace|mutate)$
^/api/credentials\.(describe|set|unset)$
^/api/agentPreset\.(read|copy|openDocument|remove)$
^/api/host\.(pickDirectory|openPath)$
^/api/llm\.discoverModels$
```
Plus operator-supplied `privilegedExtra` regexes (invalid regexes silently swallowed).

`lib/access.js:186-198` `ADMINISTRATIVE_ROUTES` adds plugin-local paths and two upstream prefixes: `/api/settings`, `/api/plugins` (prefix-or-equal match, `:205-212`).

### 3.2 The plugin's regexes do NOT match the 0.1.7 wire names — VERIFIED

Upstream RPC wire format is `POST /api/<namespace>/<method>` with the JSON body carrying `{type:'client-request', rpcId, method: endpoint, payload}`:
- Client send: `packages/client/connection/src/client/rpc.ts:48-52`, route built as `` `${channel}/${endpoint}`.slice(1) `` at `:50`.
- Server parse: `packages/client/connection/src/rpc-host.ts:280-289` `endpointFromPath(channel, pathname)` slices after `/api/`.
- Single mounting point: `packages/client/connection/src/index.ts:144-158` registers the `/api` prefix; gateway intercepts at `packages/api/gateway/src/index.ts:232-238`.

So the real paths are **slash**-separated: `/api/settings/describe`, `/api/credentials/set`, `/api/llm/discoverModels`, etc. lanmode's patterns use a **dot** (`settings\.describe`). None of them match. Concretely:

| lanmode pattern | Upstream 0.1.7-rc.2 reality | Match? |
|---|---|---|
| `/api/settings.(describe\|…)` | `/api/settings/describe`, `/update`, `/replace`, `/mutate` at `packages/api/settings-controller/src/index.ts:97-152` | **NO** |
| `/api/credentials.(describe\|set\|unset)` | `/api/credentials/describe\|set\|unset` at `packages/api/settings-controller/src/credentials.ts:82,99,112` | **NO** |
| `/api/agentPreset.(read\|copy\|openDocument\|remove)` | only `list`/`read`/`select` exist (`packages/preset/agent-preset-registry/src/index.ts:170,193,318`); `copy`/`remove`/`openDocument` **do not exist** | **NO** (and partly fictitious) |
| `/api/host.(pickDirectory\|openPath)` | **no `host` RPC namespace**; equivalents `directoryPicker/pick` (`packages/api/workspace-controller/src/directory-picker.ts:54`), `session/openWorkspacePath` (`packages/api/session-controller/src/index.ts:339`) | **NO** |
| `/api/llm.discoverModels` | `/api/llm/discoverModels` (`packages/llm/llm/src/index.ts:637`) | **NO** |

Only the two broad prefixes in `ADMINISTRATIVE_ROUTES` (`/api/settings`, `/api/plugins`) actually match real traffic. So even if `unlockPrivileged` were `false`, **the PIN/refusal gate would not fire for the real privileged endpoints** — they would pass through as ordinary requests. This is a second silent no-op, independent of the loopback rewrite. (`privilegedExtra` could be used to repair it, but the defaults are wrong.)

**Status:** the *claimed* privileged-endpoint list is **UNVERIFIED/WRONG** against 0.1.7-rc.2. The names in the plugin (`settings.openDocument`, `agentPreset.copy/remove/openDocument`, `host.pickDirectory`, `host.openPath`) do not exist upstream.

### 3.3 Does upstream genuinely gate those endpoints server-side? — NO, not per-endpoint

There is **no per-endpoint loopback gate**. Every `/api` call is admitted by one central guard, `HostConnectionService.requestRejection` (`packages/client/connection/src/rpc-host.ts:104-107`):
```js
if (!isTrustedApiRequest(request, this.trustedHosts)) return 403
return this.browserAuth.isAuthenticated(request) ? undefined : 401
```
called from `admit()` (`:110-113`), used by the `/api` route (`packages/client/connection/src/index.ts:149`) and the WebSocket upgrade (`packages/api/gateway/src/index.ts:253`).

`isTrustedApiRequest` (`packages/client/connection/src/api-request-trust.ts:91-117`) is a **Host/Origin header predicate**, not a loopback check:
1. Host absent/unparsable → false (`:100-102`); else `if (!isLoopbackHostname(hostUrl.hostname) && !isTrustedAuthority(hostUrl, trustedHosts)) return false` (`:103`)
2. `sec-fetch-site === 'cross-site'` → false (`:106`)
3. Origin absent → true; else `new URL(origin).host === hostUrl.host` (`:111-117`)

The client-side `isLoopback` flag (`packages/client/connection/src/client/index.ts:248`) is a **UI affordance only**: e.g. `packages/client/ui-settings/src/client/index.ts:39` picks `'host'` vs `'memory'` persistence; `packages/client/ui-settings-general/src/client/index.ts:102` mounts the document controller only when `$host.isLoopback`. Hiding UI ≠ blocking RPC.

So lanmode's claim that "Core DSH methods strictly reject requests not originating from loopback" (README line 50) **overstates upstream**. Upstream's real defence is fence + cookie, and the fence is bypassable by forging Host+Origin (which lanmode itself proves).

### 3.4 What "locked to loopback" means concretely in lanmode

From `lib/bridge.js:265-279`: with `unlockPrivileged === false`, a request deemed privileged from a non-loopback client gets `403` with body
`dsh-lanmode: privileged call locked to loopback. Enable unlockPrivileged in settings to permit network access.` (`lib/privileged.js:154`).
When `unlockPrivileged === true` (default) and a `lanPin` **is** set, it calls `challengePin` (`:274`): 429 + `x-dsh-lan-pin-retry-after` when locked out, or 403 + `x-dsh-lan-pin-required: 1` (`lib/privileged.js:161-186`). When `unlockPrivileged === true` and no `lanPin`, the request is forwarded untouched (`lib/bridge.js:275-279` is the only remaining branch and it does not match) → **open**.

---

## 4. Auth model (plugin's own)

All in `lib/auth.js` (354 lines) + `lib/routes/auth.js`.

- **Password hashing:** scrypt. `SCRYPT_N=16384, SCRYPT_R=8, SCRYPT_P=1, SCRYPT_KEYLEN=32` (`lib/auth.js:6-9`). Stored format `scrypt$N$r$p$saltHex$hashHex` (`lib/auth.js:23-29`). Unknown-user path pays the same cost with a fixed dummy salt `Buffer.alloc(16,7)` (`lib/auth.js:11-17`) — good anti-enumeration. `verifyPasswordSecret` also accepts a **plaintext** configured password via `safeEqualStrings` (`lib/auth.js:40-48,50-77`).
- **Session token:** `crypto.randomBytes(32).toString('hex')`; only `sha256(token)` is stored (`lib/auth.js:80-82,161-200`). Good.
- **Lifetime:** default 30 days (`sessionDurationMs`, `lib/auth.js:91`); `rememberMe=false` → 24 h (`:161-200`). `maxSessions` default 500 with oldest-eviction (`:93`). Hourly cleanup timer (`:98`).
- **Lockout:** `5` consecutive failures → `lockedUntil = now + 30000` — i.e. **30 seconds** (`lib/auth.js:289-311`). Weak compared to the LAN PIN's 15 min.
- **Cookie:** name `dsh_auth_session`; `makeSessionCookie` (`lib/auth.js:342-347`) = `dsh_auth_session=<token>; Path=/; HttpOnly; SameSite=Lax; Max-Age=<n>`, with `; Secure` **only** when `state.tls?.enabled` (`lib/routes/auth.js:74`). Behind Pangolin the plugin's own TLS is off → **`Secure` is omitted even over HTTPS**, and `SameSite=Lax` (not `Strict`). ⚠️
- **Token extraction order** (`lib/auth.js:316-336`): cookie → `Authorization: Bearer` → `x-dsh-auth-session` / `x-dsh-auth-token` headers → **`[?&]auth_token=` query param**. Putting a session token in a URL is a leak risk (logs, `Referer`, history).
- **Cookie name collision with DSH core:** core uses a **per-authority** name `dsh-auth-<base64url(sha256(authority))>` (`packages/client/connection/src/browser-auth.ts:16,106-108`). Different prefix/name from `dsh_auth_session`, so no *name* collision — but both cookies are sent on every request, and lanmode **proxies to a core that expects the core cookie**. See §5 and the dead-code note below.
- **Interaction / conflict:** for the plugin's own passwordAuth to work through its bridge, the client must present `dsh_auth_session`; the core still requires its own `dsh-auth-<hash>` cookie for `/api`. In a Pangolin-fronted deployment the plugin's bridge is (or should be) bypassed entirely, so the two auth systems do not actually interoperate — they are two independent locks in series only if you route through the bridge.
- **Dead code:** `lib/dsh-auth-cookie.js` exports `pickDshAuthCookie` (regex `/^dsh-auth-[A-Za-z0-9_-]+=/`, `:4`) intended to cache core's Set-Cookie so the bridge can re-inject it (`mergeDshAuthCookie`, `:15-21`, used at `lib/bridge.js:283-286`). But `pickDshAuthCookie` is **never imported anywhere** and `state.dshAuthCookie` is **never assigned** — `lib/index.js:240` reads `state.dshAuthCookie || ''`, which is always `''`. So the "merge the core cookie" feature is inert. (grep: only the definition exists.)
- **Missing-secret footgun:** `lib/secret.js:23-44` returns **the ref string itself** when a `*Ref` cannot be resolved (returns `targetRef` as the secret, `:44`). So a typo'd `authPasswordRef` becomes a *literal password* equal to the ref name; the negative cache is only 5 s (`:11`). Resolvable, but surprising.

---

## 5. Proxy / forwarded handling

- **`trustedProxyCidrs`** default `['127.0.0.0/8','::1/128']` (`lib/config-schema.js:86-89`, `lib/bridge-utils.js:82`).
- `clientIp(req, trustedProxyCidrs)` (`lib/bridge-utils.js:89-107`): `remote = req.socket.remoteAddress`; if `remote` is **not** in the trusted list → return `remote` (XFF ignored); else prefer **`cf-connecting-ip`** (first comma segment, `:98-101`) then **`x-forwarded-for`** first segment (`:102-105`).
- **Semantics are sound in the direct case:** a direct peer cannot spoof, because its socket address isn't trusted → XFF is discarded. Spoofing requires the peer to *be* inside `trustedProxyCidrs`.
- **Risk if the proxy does not set/clear the headers:** if a *trusted* peer (e.g. `127.0.0.1` in a shared-netns container) forwards headers without sanitising, a client-supplied `X-Forwarded-For`/`CF-Connecting-IP` is believed verbatim. Pangolin must **strip** inbound `X-Forwarded-*` and `CF-Connecting-IP` and set them itself; otherwise identity/role/bans/pin-rate-limiting are all forgeable by header.
- **Inconsistency (important):** the bridge's HTTP path uses `clientIp()` (`lib/bridge.js:185`), but **the WebSocket path and all plugin-local routes use the raw socket address instead** — `lib/bridge-ws.js:20-26` (allowlist), `lib/routes/auth.js:49` (rate limit), `lib/routes/config.js:45`, `lib/routes/devices.js:27,54,105,151`, `lib/routes/tunnel.js:41`. So behind any proxy that terminates on a different host (or even on loopback) **all remote clients collapse to one identity** for allow-list/role/admin decisions on those routes. If Pangolin→container lands as `127.0.0.1`, every browser is "loopback" and therefore admin on the plugin-local routes.
- **`isCfTunnel` is spoofable:** `lib/tunnel.js:155-157` = presence of `cf-ray` / `cf-connecting-ip` / `cf-visitor`, all client-settable headers. Impact is bounded (it only *adds* a PIN challenge, `lib/bridge.js:266,274`), so it's a self-DoS / spurious-PIN vector, not an auth bypass.
- **Upstream core does not honour forwarded headers at all** — zero matches for `x-forwarded-*` / `trust proxy` in 0.1.7-rc.2. Core decides trust purely from the request's `host`/`origin`/`sec-fetch-site`/`cookie` headers (`api-request-trust.ts:99,106,111`; `browser-auth.ts:71,289`). Therefore behind Pangolin you **must** (a) preserve the real `Host`, (b) add the FQDN to `trustedHosts`, and (c) ensure the browser's `Origin` equals that Host. No forwarded-header config exists to set.

---

## 6. Network surface

| Listener / socket | Host:Port | Purpose | Evidence |
|---|---|---|---|
| Direct bridge (plain HTTP) | `directHost` (`127.0.0.1` default) : `directPort` (`3088`) | Reverse-proxies the harness, rewrites headers, runs plugin routes | `lib/index.js:132-245`, `lib/bridge.js:486-519` |
| Direct bridge (HTTPS/h2) | same, when `tls` is `self-signed`/`files` | `http2.createSecureServer(tlsServerOptions)` | `lib/bridge.js:506-512`, `lib/sni.js:34-53` |
| mDNS responder | `0.0.0.0:5353/udp` (multicast 224.0.0.251) | announce `dsh.local`, `_http/_https/_dsh._tcp.local` | `lib/mdns.js:16-17,311-323` |
| Cloudflare tunnel child | n/a (spawns `cloudflared`) | WAN tunnel when enabled | `lib/tunnel.js:57-59` |
| Harness listener | `127.0.0.1:3080` default | upstream | `packages/bundle/web-app/cordis.patch.yml:167-168` |

**Coexistence with the harness listener:** `bindAddresses(config, harnessPort)` (`lib/bind.js:11-24`) — if the wanted host isn't `0.0.0.0`/`::`/`''` **or** the port differs from the harness port, it binds exactly `[{hosts:[wanted]}]`. Only when asked to bind `0.0.0.0`/`::` **on the same port as the harness** does it enumerate non-loopback interface addresses individually (skipping `.local`, `.sslip.io`, `.nip.io`, `127.`, `::1`) to avoid `EADDRINUSE` against the harness's own `127.0.0.1` bind.

**Mode selection** (`lib/mode.js` + `lib/index.js:346-406`): `mode: auto` (the default) probes each LAN address on `webServer.port`; **if anything answers**, it concludes "existing proxy" and **opens no listener at all** (`lib/mode.js:69-75`). If nothing answers and `directPort` is free, it starts the direct listener (`:92-96`). In a container behind Pangolin, the container's own LAN address will typically NOT be bound by the harness (which binds `127.0.0.1`), so `auto` would likely choose **direct** and open `127.0.0.1:3088` — harmless (loopback only) but pointless. If the operator sets `directHost: 0.0.0.0`, it becomes an **additional exposed port** that Pangolin was not asked to protect.

**Can it be used with a proxy that preserves Host?** Only by bypassing the bridge: the bridge *rewrites* Host/Origin to `127.0.0.1:port` (`lib/bridge-utils.js:20-30`), destroying the real Host. So if Pangolin fronts lanmode's bridge, the core never sees `dsh.example.com`, and per-host policy/logging upstream is impossible. To front the harness directly, Pangolin must target `127.0.0.1:3080` (the harness), **not** the bridge, and `trustedHosts` must include the FQDN. In that topology the bridge is dead weight.

---

## 7. Threat assessment: exposure at a public FQDN behind Pangolin

### 7.1 What lanmode defends

- Fail-closed allow-list *provided the operator leaves the default*: `allow: ['127.0.0.0/8']` (`lib/config-schema.js:78-81`, `cordis.patch.yml:28`).
- Subnet role separation (`adminAllow`/`guestAllow`, `lib/access.js:148-174`) — but note the **fail-open default**: with no rules configured at all, `resolveClientRole` returns `'admin'` (`lib/access.js:173`), and `allowed()` with empty rules returns `true` (`:125-136`).
- PIN gate with PBKDF2 (100k, sha512, `lib/privileged.js:24-26,57-67`) and a **15-minute** per-IP lockout after 5 failures (`:119-152`).
- Ban list (`lib/bans.js`), device registry revocation (`lib/devices.js`), 64 KiB body cap (`lib/body-limit.js`), `Sec-Fetch-Site`/origin CSRF checks (`lib/access.js:219-239`).
- Loopback-only first-admin setup and "can't leave passwordAuth on with no credential" (`lib/admin-guard.js:9-23`).

### 7.2 What it leaves to the proxy

Everything transport: TLS termination, HSTS, certificate trust, the public IP/port, DoS/rate-limiting at the edge, and — critically — **sanitising `X-Forwarded-*` / `CF-Connecting-IP`**. It also leaves *real* client-IP fidelity to the proxy, and then partly ignores it (§5).

### 7.3 Where it WEAKENS upstream security

1. **Header forging defeats the trust fence** (`lib/bridge-utils.js:20-30`): `host` and `origin` are both rewritten to `http://127.0.0.1:<port>`. Upstream's fence (`api-request-trust.ts:111-117`) compares Origin to Host, so rewriting both passes. A remote client reaching the bridge thereby obtains the *same* `/api` admission as a local process. Upstream is explicit that this fence is "not an auth layer" (`api-request-trust.ts:1-14`) — but lanmode converts a same-origin check into a same-origin *forgery*.
2. **Forced loopback enables privileged UI for remote users**: the shim sets `__DSH_TRANSPORT__.ownsHost = true` (`lib/shim.js:15-19`) *and* `ctx.connection.isLoopback = true` (`lib/client-parts/09-apply.js:14-16`), so remote browsers see Settings/Models/path actions as if local. Combined with (1) and `unlockPrivileged: true`, remote users can drive settings/credentials.
3. **`unlockPrivileged` defaults to `true`** (`lib/config-schema.js:94-97`). With no `lanPin`, privileged traffic is unmodified (`lib/bridge.js:275-279`). The README's own example sets `directHost: 0.0.0.0` and a LAN allow-list while leaving this default (`README.md:201-207`).
4. **The plugin's anti-privilege regexes don't match real paths** (§3.2), so the PIN/refusal layer is effectively bypassed for the actual endpoints even when configured.
5. **`Secure` omitted on session cookies** whenever the plugin's own TLS is off (`lib/routes/auth.js:74`) — which is exactly our Pangolin topology.
6. **Session token accepted from a query param** (`lib/auth.js:316-336`).
7. **In-app self-updater that runs `dsh plugin add <pkg>@latest` from npm** (`lib/plugin-updater.js:198-243`) — remote code execution into the running profile. Its guard is `x-dsh-plugin-update: 1` + same-origin + `verifyAdminAccess` (`:22-34`); `verifyAdminAccess` grants admin to **loopback** (`lib/access.js:253-307`), and behind a loopback-terminating proxy every request *is* loopback on the plugin-local routes (§5). Chained with (1)–(3) this is the highest-severity item.
8. **Client-side fetch monkey-patching that fabricates a `Response`**: `installRemoteFileOpen` (`lib/client-parts/01-remote-helpers.js:144-179`) intercepts file fetches and returns a synthetic `{ok:true}` 200 while triggering a download. It hides real errors from the app and is easy to get subtly wrong.

### 7.4 The single most dangerous default

**`unlockPrivileged: true` (`lib/config-schema.js:94-97`).** It is fail-open by design and is the one default that silently converts "remote client" into "remote client with settings/credentials authority" — and it is combined with a header-forging proxy that neutralises the only server-side fence. The shipped config also sets `directHost: 127.0.0.1` + `allow: ['127.0.0.0/8']`, which masks the danger until an operator follows the README and widens exposure.

---

## 8. Compatibility risk with official 0.1.7-rc.2

- **Peer ranges are already unsatisfiable:** `peerDependencies` declares `@deepseek-ai/dsh-host-webserver: '^0.1.0-rc.6'` and `@deepseek-ai/cordis: '^4.0.1'`. Verified with semver: `^0.1.0-rc.6` **does not** satisfy `0.1.7-rc.2` (nor `0.1.5-rc.3`); it satisfies `0.1.7` (stable) only. So the declared peer range excludes the exact platform version we target — an install would warn/fail on peers, before any runtime issue.
- **Assumptions about upstream internals, and their status on 0.1.7-rc.2:**

| Assumption | Evidence | Status |
|---|---|---|
| connection bundle path `/plugins/@deepseek-ai/dsh-client-connection/client.js` | `lib/loopback-source.js:11` | matches package name `@deepseek-ai/dsh-client-connection` |
| exact `isLoopback` source substring | `lib/loopback-source.js:13` | **BROKEN** — absent in source and compiled bundle |
| privileged paths use a dot (`settings.describe`) | `lib/privileged.js:15-21` | **BROKEN** — real form is `/api/settings/describe` |
| `agentPreset.copy/remove/openDocument`, `host.pickDirectory/openPath` exist | `lib/privileged.js:15-21` | **BROKEN** — not upstream endpoints |
| `webServer.tapIndex` exists | `lib/index.js:550` | ✔ |
| `webServer.register({kind,path,handler})` | `lib/routes/*` | ✔ |
| `connection.authenticatedUrl()` | `lib/index.js:431` | ✔ |
| core sets a `dsh-auth-<hash>` cookie readable/mergeable | `lib/dsh-auth-cookie.js` | cookie exists, but the merge code is **dead** |
| `@deepseek-ai/dsh-client-ui-deliverables` bundle present/stable for its exclusion | `lib/shim.js:187-189` | **UNVERIFIED** (string not confirmed in 0.1.7-rc.2 build) |

- **Failure modes when upstream changes:**
  - Silent **degradation**, not crash: the loopback rewrite and the privileged regexes both fail closed-to-noop with only a log line. Operators see "compatibility noticed" rather than an error.
  - Client-runtime refactors break the `__ModuleLoader__` hijack `lib/shim.js:284-329` — the whole settings card and its `apply` proxy chain can disappear with a console error.
  - Any change to how `/api` paths are shaped only deepens the §3.2 mismatch.
  - `lib/assumptions.js` will report `MOUNTING POINTS DRIFTED` — that is diagnosable, but it only checks `tapIndex`, `webServer.port`, and the presence of the injected marker; it does **not** verify the loopback rewrite or the privileged path list.
- **Net:** lanmode 0.8.5 is best understood as pinned to the **0.1.6-era** client/API shape. Against 0.1.7-rc.2 its two security-relevant mechanisms are inert and its peer range is unsatisfiable.

---

## 9. Feature classification for our Pangolin design

| Feature | Verdict | One-line reason |
|---|---|---|
| mDNS (`dsh.local`) | **Don't need** | LAN discovery is meaningless for a public FQDN; adds a `0.0.0.0:5353` multicast listener and a hand-rolled DNS parser (`lib/mdns.js`). |
| TLS / Root CA / `tlsSites` / SNI | **Don't need — do not copy** | Pangolin terminates TLS. lanmode shells out to `openssl` (`lib/tls.js:117-124`), issues a **100-year** CA+leaf (`lib/tls.js:23,26`; README's "10-year" claim is stale), and would install a private root CA on clients. Actively harmful trust surface. |
| SNI multi-cert | **Don't need** | Belongs to the proxy. `lib/sni.js` exists only to serve `tlsSites`. |
| Cloudflare tunnel (`quick`/`named`) | **Don't need — dangerous** | Spawns `cloudflared` and exposes the harness on a `trycloudflare.com` URL (`lib/tunnel.js:57-59`); a second, unmanaged egress path around Pangolin. |
| QR / `/mobileqr` / pair-accept | **Probably don't need** | Convenient LAN pairing (`lib/qr.js`, `lib/bridge-local.js:58-79,362-400`) but embeds the **live launch token in a URL**; with a public FQDN we don't need a token-in-URL shortcut. |
| Device approvals / connected-device registry | **Want the idea, not the code** | Per-device session visibility + revoke is genuinely useful (`lib/devices.js`); but it persists to `~/.dsh/dsh-lanmode-devices.json`, keys on a query-param token, and collapses identity behind a proxy. Reimplement thin if needed. |
| Bans | **Don't need** | Edge/proxy or DSH can own this; `lib/bans.js` is a 75-line JSON set with no expiry. |
| Firewall checks (`ufw`/`firewall-cmd`/`netsh`) | **Never** | A plugin mutating the host firewall (`lib/firewall.js:24-79`) is unacceptable in a container; it will silently fail without root and is a privilege-escalation smell. |
| PWA / manifest / meta tags | **Want (small)** | Pure presentation; the `viewport-fit=cover` / theme-color / manifest injection (`lib/index.js:531-539`, `lib/pwa-manifest.js`) is harmless and nice on mobile. |
| Response compression | **Don't need** | Pangolin/the edge compresses; `lib/bridge.js:366-404` re-compresses with brotli/gzip and adds latency and a class of bugs. |
| Plugin updater (in-app) | **Never** | Remote-triggered `dsh plugin add` from npm (`lib/plugin-updater.js:198-243`) is an RCE primitive with a loopback-satisfiable guard. |
| Loopback shim / `__DSH_TRANSPORT__` | **Do not copy** | Dead rewrite plus a global upstream says served pages should not carry. Use `trustedHosts` instead. |
| `crypto.randomUUID` / clipboard polyfills | **Want (small, conditional)** | Legitimate for non-secure contexts; harmless under HTTPS where the native API exists (`lib/shim.js:26-71`). |
| Cache-busting / adaptive compression / pool splitting | **Don't need** | Solves a LAN-bandwidth problem we don't have. |

---

## 10. Final verdict

### Borrow (small, ideas only)
1. **Inject via `webserver/index-inject` / `tapIndex`** — this is the right, supported seam, and lanmode confirms `tapIndex` works on 0.1.7-rc.2 (`lib/index.js:550-557` matches `packages/host/webserver/src/index.ts:212-218`). Use it for *markup only* (meta tags, styles, PWA manifest link).
2. **Unconditional, cheap polyfills** guarded by feature detection (`crypto.randomUUID`, `navigator.clipboard`) — keep them native-first.
3. **PWA/mobile meta injection** — small, pure presentation.
4. **Fail-closed posture as a *pattern***: a default-deny allow-list (`allow: ['127.0.0.0/8']`) is the right default shape; just don't pair it with a fail-open privilege flag.
5. **Assumption self-check on boot** (`lib/assumptions.js`) — a 3-second post-start assertion that logs drift is a good instinct; ours should assert *our* seams, not upstream internals.

### Avoid (do not copy, in priority order)
1. **Never forge `Host`/`Origin`** (`lib/bridge-utils.js:20-30`). Use `trustedHosts: ['dsh.example.com']` (`packages/client/connection/src/index.ts:103`) so the real authority passes the fence honestly.
2. **Never inject `__DSH_TRANSPORT__` into a served page.** Upstream states served pages never carry it (`packages/client/connection/src/client/index.ts:96-104`); rely on `trustedHosts` + DSH's own auth.
3. **Never text-replace a minified upstream bundle** (`lib/loopback-source.js:13`). It is already a no-op on our target, and it is unbounded version risk.
4. **Never enable a fail-open privilege flag by default** (`unlockPrivileged: true`).
5. **Never add a second listener when a proxy exists** — keep `mode: proxy` (or ensure the container's address answers so `auto` resolves to proxy) so the only exposed path is the harness behind Pangolin.
6. **Never run an in-app npm self-updater** (`lib/plugin-updater.js`).
7. **Never mutate the host firewall** (`lib/firewall.js`).
8. **Never spawn `cloudflared`** (`lib/tunnel.js`).
9. **Do not hand-roll session cookies** (`dsh_auth_session`, `SameSite=Lax`, conditional `Secure`) — use DSH's own browser auth; it already sets `HttpOnly; SameSite=Strict` with a per-authority name and HMAC-SHA256 signing (`packages/client/connection/src/browser-auth.ts:121-159`).
10. **Do not monkey-patch `window.__ModuleLoader__`, `window.fetch`, or `ctx.connection.isLoopback`** (`lib/shim.js:246-329`, `lib/client-parts/01-remote-helpers.js:104-179`, `lib/client-parts/09-apply.js:14-16`).

### Minimal correct recipe for our design
- Run official DSH 0.1.7-rc.2 bound to `127.0.0.1:3080` (its secure default; `--host 0.0.0.0` is rejected upstream at `packages/bundle/web-app/src/startup.ts:75-77`).
- Pangolin terminates TLS and proxies to the container, **preserving the real `Host`** (`dsh.example.com`) and **stripping inbound `X-Forwarded-*`/`CF-Connecting-IP`**.
- Set `trustedHosts: ['dsh.example.com']` on the client-connection plugin so the Host/Origin fence accepts the public authority (`packages/client/connection/src/index.ts:103,132`).
- Let DSH's launch-token → signed `HttpOnly; SameSite=Strict` cookie do authentication (`packages/client/connection/src/browser-auth.ts:238-300`). Force `Secure` on the cookie — note upstream omits it (`:121-123`), so this is the one thing to verify/override in our recipe.
- Inject only presentation markup through `webserver/index-inject`. Nothing else.
- Do **not** install lanmode.

---

## REMAINS UNVERIFIED

1. **Fully compiled/minified `lib/client.js` for lanmode's *own* client** and whether the `__ModuleLoader__` hijack still functions against the 0.1.7-rc.2 client runtime (only the source was audited; no runtime test was permitted).
2. **`@deepseek-ai/dsh-client-ui-deliverables` presence under 0.1.7-rc.2** — the exclusion at `lib/shim.js:187-189` depends on that bundle id; I did not confirm the built bundle list.
3. **Whether the 0.1.7-rc.2 client runtime still exposes `window.__ModuleLoader__` with a `pendingQueue`** (assumed by `lib/shim.js:284-329`); source-only checkout could not confirm the assembled client runtime.
4. **Exact upstream RPC endpoints for `agentPreset` beyond `list`/`read`/`select`**, and any permission/preset endpoints lanmode may have intended — the `copy`/`remove`/`openDocument` names were not found.
5. **Whether any upstream code path other than the shared `/api` guard adds a per-endpoint privilege check** — none found, but the search was grep-based across `packages/api` and `packages/client/connection`.
6. **Behaviour of the direct bridge against a 0.1.7-rc.2 harness at runtime** (was not run; audit is read-only). In particular whether the forged `Host: 127.0.0.1:<port>` still satisfies core's index authorization and cookie authority binding (`browser-auth.ts:287-300` binds the cookie to the request authority, so a forged authority likely invalidates a browser's real cookie — this would make the bridge broken for authenticated browsers and is UNVERIFIED).
7. **lanmode's own test suite** — not shipped in the published package; could not be inspected or run, so behavioural claims rest on source reading alone.
8. **Pangolin's exact header behaviour** (whether it preserves `Host`, strips `X-Forwarded-*`, and what source address the container sees) — outside this repo; asserted as a requirement, not verified.
