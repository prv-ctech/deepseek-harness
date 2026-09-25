# DSH 0.1.7-rc.2 architecture audit — containerization + TLS reverse proxy

Checkout: `/tmp/dsh-research/official`, detached tag `dsh-v0.1.7-rc.2` == commit `477b4f420553e8a52c2fbccc464d7561b239c443`. Read-only; nothing edited, installed, or served.

Scope: how the supported `dsh web` profile works end to end — argv → config composition (Cordis patches/bundles) → HTTP server → WebSocket → browser client — with no loopback/localhost assumptions, so it can be containerized behind a TLS-terminating public-FQDN reverse proxy (Pangolin).

---

## Q1. Config composition

### Entry / argv
- `apps/cli/src/bin.ts:18` `runCli()` — `parseDshArgs(process.argv.slice(2), version)`; dispatch by `invocation.mode`: `profile` → dynamic `import('./profile-boot.ts').runProfile({environment: loadLayeredEnv('dsh'), profile, fromDefaultProfile, patchFiles, args})`; `plugin` → `runPlugin` then `process.exit(code)`; `dump-config` / `dump-config-schema`. `StartupError` → `reportStartupFailure` + `process.exit(1)`. `bin.ts:65-67` `if (import.meta.main) await runCli()`.
- `apps/cli/src/args.ts:145` `parseDshArgs` builds a commander program with `.passThroughOptions()`, `.enablePositionalOptions()`, `.allowUnknownOption()`, `.helpOption(false)`. Launcher flags parse first; the first unknown token begins inner app args.
- Bare-subcommand expansion (`args.ts:200-203`): `first !== undefined && !first.startsWith('-') && first !== 'plugin'` → `['--profile', ...argv]`. So `dsh web …` == `dsh --profile web …`.
- Launcher flags: `--profile <name>` (`selectProfile`, rejects a second occurrence), `--from-default-profile <name>`, `--patch <path>` (repeatable), `--dump-config`, `--dump-config-schema`, `--dump-default-config`.
- `--patch` is a **repeatable single-value collector**, deliberately non-variadic: `const collect = (value, previous = []) => [...previous, value]` (`args.ts:75-76`) — a variadic `--patch` would swallow the inner app arguments.
- `resolveBoot` (`args.ts:109-142`): empty `--patch` path → `error: --patch needs a path`; `--from-default-profile ''` → error; multiple dump flags → mutually exclusive; dumps take no app args; `--dump-default-config` + `--patch` → `error: --dump-default-config prints the bundle layers and takes no --patch`.
- `profile` "desktop" is rejected (`args.ts:83-87`): `error: profile "desktop" is managed exclusively by the Electron application`.
- `plugin` subcommand (`args.ts:186-198`): requires `--profile`, `allowUnknownOption()`, forwards remaining args verbatim to pnpm.

### Boot sequence
`apps/cli/src/profile-boot.ts:244` `runProfile(options)`:
1. `installProxyFromEnvironment` (before any plugin mounts).
2. `createProcessShutdown(dispose)`; `signalShutdown` AbortController; `process.on('SIGTERM', () => interrupt(0))`, `process.on('SIGINT', () => interrupt(130))` (`:280-281`); `installFailLoud`.
3. `composeProfile(...)`; then `boot(NAME, rootConfig, readProfilePatches(...), prepare)`; `prepare` provides `profileContext`, `DSH_LAUNCH_ENVIRONMENT_KEY`, PluginPackages, `provideCmdline({args, exit, ready})`.
4. `appReady.commit()` only if not aborted **and** `ctx.fiber.state === FiberState.ACTIVE` **and** `ctx.loader` exists (`:314-317`).

### Layer order
`profile-boot.ts:181-184` documents and `:196-209` implements:
1. Bundle layers in `dsh.profile.bundles` order (`profile.layers.flatMap(layer => layer.patches)`).
2. The profile's own `cordis.patch.yml` (user layer).
3. **Home layer** `$DSH_HOME/cordis.patch.yml` — applied **over** the per-profile layer, so machine-local preferences outrank the profile layer.
4. `--patch` overlays, in argv order: `overlays = patchFiles.flatMap(file => loadOverlayPatches(NAME, resolve(file)))`.
5. Telemetry-disable switch (`resolveTelemetryPatch`) if `DSH_TELEMETRY_DISABLED` is set and the `session-telemetry-otel` row exists.

`prepareProfile` (`:185-193`) writes the literal `PROFILE_ROOT_CONFIG` (an empty YAML array) to `$DSH_HOME/profiles/<name>/cordis.yml` on every boot, then `loadProfile` + `reportSkippedBundles`. The root config is intentionally empty because Loader tree write-back would otherwise bake the composed rows into the profile root.

- `readProfilePatches` (`packages/boot/app-boot/src/profile-context.ts:63-74`) reads the home-layer path.
- `homePatchPath()` = `join(resolveDshHome(), PROFILE_PATCH_FILENAME)` (`profile-boot.ts:73-75`); `PROFILE_PATCH_FILENAME = 'cordis.patch.yml'`, `PROFILES_DIR = 'profiles'`, `PROFILE_ROOT_FILENAME = 'cordis.yml'` (`packages/boot/app-boot/src/profile.ts:37-40,88`).

### Profiles / bundles
- `PROFILE_TEMPLATES` (`profile.ts:179-195`): **web = `['@deepseek-ai/dsh-base','@deepseek-ai/dsh-web-app']`**; acp = base+acp-app; headless = base+headless; sdk = base+sdk-app; sdk-minimal = `['@deepseek-ai/dsh-sdk-minimal']`. `DEFAULT_PROFILE_BUNDLES = ['@deepseek-ai/dsh-base']`.
- `initProfile(dir,bundles)` (`:243-262`) writes `package.json` `{name:'dsh-profile-<basename>', private:true, dependencies:{}, dsh:{profile:{bundles}}}` plus an empty-array `cordis.patch.yml` template, and `pnpm-workspace.yaml` with `nodeLinker: hoisted`, `autoInstallPeers: false`.
- `resolveBundleDir` (`:629-640`) tries **installAnchor first**, then profileDir — in-box bundles always come from the running installation, never a profile-local copy. `INSTALL_ANCHOR = fileURLToPath(new URL('../package.json', import.meta.url))` (`profile-boot.ts:78`).
- A bundle package must declare `dsh.bundle.patch` (string or list). Unreadable/incompatible bundles are **silently skipped** with a stderr line via `reportSkippedBundles`.
- `OPTIONAL_BUNDLES` (`:213-217`): experimental-agent-team-profile, experimental-voice-input-bundle, experimental-auto-review.

### Patch parsing and `!!js`
- `loadOverlayPatches` (missing file **throws**) vs `loadOptionalPatches` (missing = no layer) — `packages/boot/app-boot/src/index.ts:315-343`. Both `yaml.load(content, { schema: userPatchesSchema })` where `userPatchesSchema = entryListSchema` from `@deepseek-ai/cordis-plugin-include` — **the same dialect the include plugin uses**, so patch parsing and config dumping cannot drift.
- Top level must be an **array of mappings**. `!!js` scalars become expression **nodes** interpolated by the Loader against the target row's injection-ready ctx; they may reference `process.env` (used heavily, e.g. `process.env.DSH_PERMISSION_MODE`, `dshHomePath('sessions')`, `ctx.webStartup.host`).
- `anchorInsertedPluginNames` (`index.ts:346-356`): inserted `name` values that are absolute or start `./`/`../` are rewritten to `file://` URLs anchored beside the patch file — this is how a profile patch can insert a local plugin.
- **Patch semantics**: a patch replaces the targeted row's **whole `config`**. Each row that is patched must restate every key it owns (stated in the `web-app/cordis.patch.yml` header and in the README's "Patch semantics").
- `composeEntries(layers, warn)` (`profile.ts:730-737`): `applyEntryPatches([], structuredClone(layers.flat()), warn)`.
- `boot()` (`index.ts:972-1038`): `pathToFileURL(dirname(config))` as baseUrl; provides `dshHomePath`, Loader; `mountRootInclude`; `auditStartupEntries`. Errors: `host preparation failed` (before configure), `plugin tree failed to load` (after).
- `loadOverlayPatches` is the only layer allowed to throw on a missing file; `--patch` paths are resolved with `resolve(file)` against cwd.

### Exact effect of `--patch`
Each `--patch <file>` appends one overlay layer applied **after** the home layer, in argv order. The file must exist (throws otherwise). It is a full `PatchOptions[]` list in the same dialect as `cordis.patch.yml`; top-level must be an array. Because a patch replaces the whole `config`, an overlay adding e.g. a trusted host must restate `trustedHosts` in full (typically keeping the `!!js` expression and concatenating).

### Webserver + connection + web-app rows
`packages/bundle/web-app/cordis.patch.yml`:
- Line 44 begins `- insert:` (web host rows). Row `web-startup` = `@deepseek-ai/dsh-web-app/startup` (parses the web flags; injects `cmdlineArgs`).
- Row `webserver` (~line 163): name `@deepseek-ai/dsh-host-webserver`, `inject: [webStartup]`, config:
  ```yaml
  host: !!js ctx.webStartup.host ?? '127.0.0.1'
  port: !!js ctx.webStartup.port ?? 3080
  compression: gzip
  compressionLevel: 1
  compressionThresholdBytes: 1024
  ```
- Row `web-runtime` (~line 185): name `@deepseek-ai/dsh-web-app`, `inject: [webStartup]`, config `openBrowser: !!js ctx.webStartup.openBrowser`, `printUrl: true`, `surfaceContext: true`, `trustedHosts: !!js ctx.webStartup.trustedHosts`.
- Row `connection` (~line 210): name `@deepseek-ai/dsh-client-connection`, `inject: [webRuntime]`, config `trustedHosts: !!js ctx.webRuntime.trustedHosts`. Preceded by a comment stating a deployment adding authorities keeps the expression and concatenates literals, e.g. `['app.internal', ...ctx.webRuntime.trustedHosts]`.
- Other rows: `client-hmr`, `modules` (`@deepseek-ai/dsh-client-modules`, serves `/plugins/<id>/client.js`), `file-upload`, `api-remotes`, `cordis-client-runner`, `ui-theme`. Tail (line 552-561) inserts `agent-preset-registry` (`@deepseek-ai/dsh-agent-preset-registry`, default preset `standard`); presets are separate patch files listed in `package.json` `dsh.bundle.patch`.

`packages/bundle/base/cordis.patch.yml` — **one giant `- insert:` list at line 15** over the empty profile root. It has **NO** webserver/connection/frontend/web rows (those are web-app-bundle-only). Row ids include: `timer`, `hmr` (`config root: []`), `llm`, `session`, `settings` (disabled when `!profileContext`), `credentials` (`@deepseek-ai/dsh-credentials-local`), `session-persistence-jsonl` (`root: !!js dshHomePath('sessions')`), `storage(165)`, `storage-json(168, root: !!js dshHomePath('storages'))`, `storage-domain(173)`, `session-telemetry-otel(204)`, `subprocess(219)`, `sandbox(225)`, `sandbox-policy(228)`, `bash-sandbox(234)`, `pwsh-sandbox(240)`, `approval(244)`, `permission(249)`, `shell-env(263)`, `tool-bash(266)`, `fs-observation-policy(277)`, `tool-fs(280)`. `plugin-manager` and `hmr` are disabled without `profileContext` (dump/embedded modes).

---

## Q2. Host / port

`packages/bundle/web-app/src/startup.ts` (`webCommand()`, name `dsh --profile web`):
- Options: `--host <host>`, `--no-open`, `--port <port>` (doc: "pass 0 to let the OS pick a free one"), `--trusted-host <authority...>` (repeatable).
- `--port` must match `/^\d+$/` else error (`startup.ts:77-79`).
- **`--host 0.0.0.0` is rejected in the action** (`startup.ts:74-76`):
  `error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code execution to the network; use 127.0.0.1 instead`
- The action provides service `WEB_STARTUP_SERVICE = 'webStartup'` (`inject: ['cmdlineArgs']`) with `{openBrowser, host?, port?, trustedHosts}`. On `--help` or error nothing is provided → **no server binds**.

**Why the schema accepts it anyway**: `packages/host/webserver/src/index.ts:126-132`:
```ts
host: z.union([z.const('127.0.0.1'), z.const('0.0.0.0')]).required()
port: z.natural().max(65535).required()
compression: z.union(['none','gzip']); compressionLevel 0..9; compressionThresholdBytes natural
```
Doc at `:59-60`: "Listen host; the two supported values are loopback and all-interfaces." So `0.0.0.0` is schema-legal; **only the CLI flag refuses it**. The webserver's own config is the trust boundary, and the fence (Q3) is what makes a public bind safe.

Actual listen: `webserver/src/index.ts:293-301` `this.server.listen(this.config.port, this.config.host, ...)`; `get port()` returns the OS-assigned listened port; `get host()` returns the literal.

**To bind all interfaces without the CLI**, a patch overlay must target row id `webserver` and restate its full config, e.g.:
```yaml
- id: webserver
  config:
    host: 0.0.0.0
    port: 3080
    compression: gzip
    compressionLevel: 1
    compressionThresholdBytes: 1024
```
Other places a host/port is chosen:
- `packages/bundle/web-app/src/index.ts:125-131` `resolveLanTrust(bindHost, extra)`: `0.0.0.0` → every non-internal IPv4 interface address as **port-less** literals; else `[]`. Returns `{lanAddresses, trustedHosts: [...lanAddresses, ...extra]}`. Sampled **once** at apply (`index.ts:226`).
- `localWebUrl` always `http://127.0.0.1:${ctx.get('webServer').port}` (`index.ts:149-153`).
- Announce (`index.ts:252-282`): `console.log('dsh web: <authenticatedUrl>' + (lan ? ' (LAN: <lanUrl>)' : ''))`, only if `config.printUrl`; browser handoff unless launched through SSH or `--no-open`; waits `loader.await()` + `auditStartupEntries` first.
- README "Known Limitations": **"Binding all network interfaces is not supported — `--host 0.0.0.0` is rejected at startup for safety; use the default loopback host."**

---

## Q3. Trust / origin fence (`/api`)

`packages/client/connection/src/api-request-trust.ts`:
- `isTrustedApiRequest(request, trustedHosts)` (`:91-118`):
  1. `Host` header **required** → else `false`; unparsable → `false`.
  2. `if (!isLoopbackHostname(hostUrl.hostname) && !isTrustedAuthority(hostUrl, trustedHosts)) return false`.
  3. `sec-fetch-site: cross-site` → `false`.
  4. `Origin`: absent → **true**; present → **strict** `new URL(origin).host === hostUrl.host` else `false` (opaque `null` refused).
  No authentication in this function — the cookie check is separate.
- `assertTrustedAuthority(entry)` (`:36-52`): entry must be a **bare canonical authority** (`host` or `host:port`). Canonical form computed by WHATWG parsing under `http`, and if the port came out empty also under `https` (so `:80`/`:443` count as explicit). Rejects paths, `user@`, whitespace, dangling colon, zero-padded port, non-canonical host spellings (`0x7f.0.0.1`, percent-encoding, unbracketed IPv6); IDN must be **punycode**. Failure throws:
  `client-connection: trustedHosts entry <JSON> is not a bare host[:port] authority`.
- `isTrustedAuthority` (`:75-84`): explicit-port entry matches exact `entryUrl.host === hostUrl.host`; **port-less entry matches hostname on ANY port**.
- `isLoopbackHostname` (`loopback-hostname.ts:12-18`): true for `localhost`, `[::1]`, or a `127/8` IPv4 literal.

**Consumers of `trustedHosts`** (the only ones): `HostConnectionService` constructor + `requestRejection` (`rpc-host.ts:75-107`):
```ts
if (!isTrustedApiRequest(request, this.trustedHosts)) return 403
return this.browserAuth.isAuthenticated(request) ? undefined : 401
```
wired from `packages/client/connection/src/index.ts:124-159`; config schema `trustedHosts` default `[]`, each entry `assertTrustedAuthority` at load, `cookieMaxAgeDays` `z.natural().min(1).default(30)`, `maxRequestBodyBytes` default 300 MiB, `recovery` default `{}`.

**Population path**: CLI `--trusted-host` → `webStartup.trustedHosts` (`startup.ts:84`) → web-app config `trustedHosts` → `webRuntime.trustedHosts` (`web-app/src/index.ts:226,231`) → connection row `trustedHosts: !!js ctx.webRuntime.trustedHosts`. `resolveLanTrust` adds port-less IPv4 literals only for an all-interfaces bind.

**Routes covered**:
- `/api` prefix route (`connection/src/index.ts:139-159`): handler `connection.admit(req)`; on rejection `res.writeHead(code)` + body `unauthorized` (401) / `forbidden` (403); else waterfall `connection/request` then bridge.
- WebSocket mux (`packages/api/gateway/src/index.ts:239-262`): upgrade at `REMOTE_STREAM_MUX_PATH = '/api/remote.mux'` (`stream-protocol.ts:7`) calls `webCtx.connection.admit(req)` → `rejectRemoteStreamUpgrade(socket, 401|403)` (`stream-server.ts:429-441`) else `mux.handleUpgrade`. **Upgrades share the same Host/Origin + cookie fence.**
- Static frontend (`frontend-static`, Q6): index responses pass `ctx.connection.authorizeIndex(req,res)`; non-index assets are public.

**TLS-terminating proxy that preserves Host**: the browser's `Host`/`Origin` is the public FQDN (`dsh.example.com`). The loopback branch fails, so the request is **403 unless `dsh.example.com` is in `trustedHosts`** (CLI `--trusted-host dsh.example.com`, or a patch on the connection row). The fence never consults scheme, `X-Forwarded-Proto`, or a route prefix.
- A proxy that **rewrites Host to `127.0.0.1:3080`** passes branch 2 but then the browser `Origin: https://dsh.example.com` fails branch 4 (`origin.host !== hostUrl.host`) → 403. So: **preserve Host AND trust the FQDN.**
- A **port-less** `trustedHosts` entry matches the FQDN on any port, which is the right shape for a proxy that may terminate on 443 (port omitted) — but if the proxy forwards `Host: dsh.example.com:443`, the port would be present, so either match the port or ensure Host has none.

---

## Q4. Auth (launch token → cookie)

`packages/client/connection/src/browser-auth.ts`:
- `AUTH_RECORD_KEY = credentialKey('client-connection','browser-session')` (`:12`). `SECRET_BYTES=32`, `TOKEN_QUERY='token'`, `COOKIE_PREFIX='dsh-auth-'`, payload version 1.
- **Launch token** `processLaunchToken(owner)` (`:20,52-58`): 32 random bytes base64url, **memoized per root context, never persisted**, new every process.
- `authenticatedUrl(baseUrl)` (`:223-227`): sets `?token=<launchToken>` onto the caller's URL (authority + mount preserved).
- `authorizeIndex(req,res)` (`:238-280`):
  - Token present → valid only if `GET && url.pathname === '/' && exactly one token && tokenMatches(token, launchToken)`; then **303 with `location: './'`**, `cache-control: no-store`, `referrer-policy: no-referrer`, and
    `set-cookie: <cookieName(authority)>=<value>; Max-Age=<maxAgeSeconds>; Path=/; Expires=<UTC>; HttpOnly; SameSite=Strict`
  - **There is NO `Secure` attribute** (`sessionCookie`, `:120-123`).
  - If token present but invalid → 401 text `dsh web authentication required; reopen the URL printed by dsh web.` (`writeUnauthorized`, `:302-310`).
  - If no token: cookie-authenticated → an authed `GET /` is 303'd to `./`; otherwise 401.
- **Cookie name = `'dsh-auth-' + base64url(sha256(authority))`** (`:106-108`) — the name, payload, and signature are all **authority-dependent**; `authority` = `new URL('http://' + Host).host` (`requestAuthority`, `:70-78`).
- **Value** = `v1.<base64url(JSON payload)>.<base64url(HMAC-SHA256(secret, body))>`, payload `{version, authority, issuedAt, expiresAt}`.
- `isAuthenticated` (`:287-300`): re-derives authority from the current request's Host, then requires `payload.authority === authority && issuedAt <= now < expiresAt && lifetime <= maxAge`.
- **HMAC secret storage**: `initializeSecret` (`:161-178`) via the credentials provider `credentials.modifyRecord(AUTH_RECORD_KEY, …)`, creating `{kind:'grant', payload:{version:1, secret: base64url(32 random bytes)}}` if absent. Persisted in **`$DSH_HOME/.credentials.yaml`**, so cookies survive restarts.
- **Revocation**: only replacing/removing that credential record invalidates cookies. A restart keeps cookies valid but rotates the launch token, so the URL must be reopened.
- **First-load redirect flow**: server prints `dsh web: http://127.0.0.1:3080/?token=<launch>`; browser GETs `/` with the token → server 303 `./` + `Set-Cookie`; browser re-requests the directory without the token → cookie verified → index served.

**Where a reverse proxy can break it**:
1. **Port in cookie authority**: the minted authority is whatever `Host` says. If the proxy preserves `dsh.example.com` (no port), the cookie authority is portless; if it rewrites Host to `dsh.example.com:443` or `127.0.0.1:3080`, the authority differs from the browser's next request Host and every request is 401. **Host must be identical and stable across the token GET, the redirect, and later requests.**
2. **Subpath**: `authorizeIndex` only mints on `url.pathname === '/'` (after prefix stripping it is `/`), and redirects to `./` (document-relative), so a prefix-stripping mount works; a proxy that forwards the prefix (`/tools/dsh/`) un-stripped makes `pathname !== '/'` → no mint → 401.
3. **Cookie `Path=/`**: the server sets `Path=/`; behind a subpath the proxy must rewrite the `Path` attribute (see Q6 fixture `prefix-proxy.ts`: `value.replace(/(^|;\s*)Path=\/(?=;|$)/iu, `$1Path=${prefix}`)`). It only matches a bare `Path=/`, not `Path=/foo`.
4. **Cookie rewriting/stripping**: any proxy that strips `Set-Cookie`, changes its domain, or normalizes its value breaks persistence.
5. **No `Secure`**: the cookie is sent over plain HTTP too; TLS termination must be enforced at the proxy (this code has no HSTS/CSP layer).
6. **`SameSite=Strict`** requires same-site top-level navigation — fine for a direct FQDN visit; breaks if embedded/iframed from another site.

---

## Q5. Client loopback gate

Computed in `packages/client/connection/src/client/index.ts:248`:
```ts
isLoopback: transport?.ownsHost === true || pageLocation === undefined || isLoopbackHostname(pageLocation.hostname)
```
Doc at `:100`: reports the privileged surface. It is fixed for the page lifetime.

**Every consumer**:
| Consumer | Path | What it gates |
|---|---|---|
| Settings core | `packages/client/ui-settings/src/client/index.ts:39` | `persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'` — **persistence selection only** |
| Settings → General | `packages/client/ui-settings-general/src/client/index.ts:102` | same class of branch (document controller behavior) |
| API gateway | `packages/api/gateway/src/client/index.ts:123,194-197` | publishes `hostFacts {home, isLoopback}` |
| Settings → Models | `packages/client/ui-settings-models/src/client/index.ts:108` | comment only — delegates to the settings core branch; no independent gate |

**There is no server-side loopback gate for settings/credentials/model endpoints.** Grepping settings/credentials/api/host for `isLoopback`/`isLoopbackHostname` found only unrelated loopback uses (`deepseek-account` callback origin, account-platform HTTPS-or-loopback validation, directory-picker-auto). Server authorization for `/api` is the **Host/Origin fence + cookie** (Q3), nothing else. The non-loopback restriction is **purely client-side persistence/UI selection** (a remote page keeps settings in memory rather than the host store).

**Index-inject / `__DSH_TRANSPORT__`**:
- Event `'webserver/index-inject'` (table `IndexInjection[]`) declared `packages/host/webserver/src/index.ts:34`; emitted once by `collectIndexInjections()` (`:343-350`); `renderIndex(html)` renders injections + raw taps.
- `IndexInjection` union (`packages/host/webserver/src/injections.ts`): `{kind:'global', name, value}` → `<script>globalThis[name]=value</script>` in head (escapes `<`); `{kind:'script', placement, text}`; `{kind:'script-src', placement, src}`; `{kind:'script-preload', src}`; `{kind:'style', text}`; `{kind:'html', placement, html}`. `renderIndexInjections` splices head rows after `<head>` and body rows after `<body>`, then appends `(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()`.
- First-party listeners: `experimental/inspector/src/host/plugin.ts:49`, `client/ui-theme/src/index.ts:41`, `ui-sidebar-documentpreview:14`, `ui-settings-models:15`, `ui-settings-account:50`, `shortcuts:16`, `client/modules/src/index.ts:654`, `client/connection/src/index.ts:141` (pushes `{kind:'global', name:'__DSH_CONNECTION_RECOVERY__', value: recovery}`).
- **`__DSH_TRANSPORT__` is never set by any official served page.** The 51 hits are: `apps/web/src/main.ts:25-26` (`transport.__DSH_TRANSPORT__ = {ownsHost: true, streamBaseUrl}` — the static/desktop shell only), `experimental/webworker-runtime/src/client/index.ts:157`, and tests. Consumers: `client/connection/src/client/index.ts:111/320` (`ClientTransportHooks`, drives `isLoopback`), `api/gateway/…/stream-client.ts:476-477` (`streamBaseUrl ?? document.baseURI`), `client/web/src/boot.ts:69-70` (`loadBundle`), `ui-settings-account/src/client/index.ts:187-188`.
- **Conclusion**: for a served web page, the supported mechanism is `document.baseURI` (set by the injected `<base href="./">`), **not** `__DSH_TRANSPORT__`. If a deployment wanted to force a transport origin, the schema-legal route is a custom `'webserver/index-inject'` `{kind:'global', name:'__DSH_TRANSPORT__', value:{…}}` row — but **no official package does this**, so it is a fork/custom-plugin change, not a config-only change.

---

## Q6. Reverse-proxy / subpath support

The 0.1.7 change is commit **`eeb9b03465` "feat(web): serve the shell, API and plugin resources from the document directory"** (merged before this rc). Design: `.agents/notes/implemented/architecture/2026-09-14-web-document-relative-app-routes.md` (47 lines).
- Problem: every browser route ref was origin-root absolute (`/api`, `/plugins`, stream mux, HMR, redirect to `/`); behind a prefix-stripping mount `https://host/tools/dsh/` everything 404'd. One bundle must serve origin root **and** any mount without a second build.
- Decision: the served index carries exactly one `<base href="./">`, spliced after the opening `<head>` by `packages/host/frontend-static/src/index.ts:117-120`:
  `body.replace(/<head(?:\s[^>]*)?>/i, open => `${open}<base href="./">`)`, **after** index transforms (comment `:116`: "Insert after all index transforms so the base precedes every resource reference").
- Browser refs become document-relative via `KEY.slice(1)`; server route keys stay absolute. Supported entries: `/mount/` and `/mount/index.html` only; a bare `/mount` needs proxy slash-normalization.
- Concrete client changes: `stream-client.ts remoteStreamUrl()` = `new URL(REMOTE_STREAM_MUX_PATH.slice(1), globals.__DSH_TRANSPORT__?.streamBaseUrl ?? document.baseURI)` then protocol `ws:`/`wss:`; `client/connection/src/client/rpc.ts` posts ``route = `${channel}/${endpoint}`.slice(1)``; `browser-auth.ts` keeps authority+mount and 303s to `./`.
- Vite base: `apps/web/vite.config.ts:171` `base: './'`.
- Reference proxy fixture `apps/web/tests/prefix-proxy.ts` (145 lines): **preserve external Host, strip the prefix, delete hop-by-hop headers `['connection','keep-alive','proxy-connection','transfer-encoding','upgrade','te','trailer']`, forward WebSocket upgrades, rewrite backend cookies `Path=/` → `Path=${prefix}`**. TLS terminates at the real deployment proxy.
- What breaks at root FQDN: **nothing** — `base './'` resolves to origin root. At subpath: the proxy must strip the prefix, preserve Host, forward upgrades, and rewrite the cookie Path; a deep in-page path reload re-enters at that path, not the frozen entry directory.

---

## Q7. Sandbox / permissions

- Modes: `packages/sandbox/sandbox/src/index.ts:30` `type SandboxMode = 'read-only' | 'workspace-write' | 'danger-full-access'`; list in `sandbox-policy/src/session-mode.ts:42`.
- **Deployment default is `workspace-write`**, decided by the shipped bundle not the schema: `packages/bundle/base/cordis.patch.yml:228-231`:
  ```yaml
  - id: sandbox-policy
    config:
      mode: !!js process.env.DSH_PERMISSION_MODE ?? 'workspace-write'
      workspaceRoot: !!js process.cwd()
  ```
  The package schema default is `read-only` (`sandbox-policy/src/index.ts`).
- Approval row (`:244-247`): `policy: !!js "(process.env.DSH_PERMISSION_MODE ?? 'workspace-write') === 'danger-full-access' ? 'never' : 'ask'"`. Permission presets (`:249-262`): read-only → sandbox read-only/approval ask; workspace-write → workspace-write/ask; danger-full-access → danger-full-access/never.
- Runner chain `packages/sandbox/sandbox-local/src/index.ts:160-167`:
  `PLATFORM_CHAINS = { linux: ['bwrap','landlock'], darwin: ['seatbelt'], win32: ['windows-acl'] }`.
  `chainVerdict()` (`:508-521`): empty chain → `unavailable`; a **sole** candidate is returned **unprobed** (its execution-time refusal still fails closed); multiple candidates are probed in order; none usable → `unavailable`. `selectRunner` (`:497-505`) memoizes and throws `SandboxUnavailableError(mode)`.
- Failure message (`packages/sandbox/sandbox/src/index.ts:132-145`, code `SANDBOX_UNAVAILABLE`):
  `sandbox mode "<mode>" is requested but no sandbox backend is usable on this host; refusing to run the command unconfined. Install bubblewrap or run a Landlock-enforcing kernel (Linux), ensure sandbox-exec is usable (macOS), or ensure the ACL restricted-token runner can start (Windows) — otherwise switch the consumer to danger-full-access.`
- Probes: bwrap `spawnSync('bwrap', [...bwrapProfileArgs(...), '--', 'true'])` exit 0; landlock launcher probe; seatbelt `sandbox-exec -p`; windows-acl runs cmd exit 0. An explicit `runnerCommand` (non-empty argv) skips probing, asserts full enforcement, and appends `bwrapProfileArgs` (`:326-334`).
- Enforcement: `bwrap`/`landlock`/`seatbelt` = **full**; `windows-acl` = **partial** (`STATIC_ENFORCEMENT :178-189`).
- **danger-full-access bypasses the provider entirely**:
  - `packages/terminal/terminal-bash/src/index.ts:102` `if (policy.mode === 'danger-full-access') return argv`
  - `packages/fs/fs-sandbox/src/index.ts:125` `if (mode === 'danger-full-access') return target`
  - `packages/ptc-runtime/ptc-runtime-node/src/index.ts:224` `confined = policy.mode === 'danger-full-access' ? undefined : await this.ctx.sandbox.confine(...)`
  - (`packages/ssh/ssh/src/helper.ts:145` throws `Unconfined argv does not need a sandbox wrapper`.)
- **Clean disable without source patch**: set `DSH_PERMISSION_MODE=danger-full-access` env **and/or** a patch setting row `sandbox-policy` `mode: danger-full-access` (a config replacement must also restate `workspaceRoot`, e.g. `workspaceRoot: !!js process.cwd()`).
- Container caveat: a container that lacks `bwrap` **and** runs a kernel without Landlock will refuse to run any confined command with `SANDBOX_UNAVAILABLE`. Either install bubblewrap (needs the right namespaces/privileges in the container) or set `DSH_PERMISSION_MODE=danger-full-access`.

---

## Q8. Filesystem / state layout

`packages/util/home-paths/src/index.ts`:
- `DSH_HOME_DIR_NAME = '.dsh'` (`:12`), `DSH_HOME_ENV = 'DSH_HOME'` (`:18`), `defaultDshHome() = join(homedir(), '.dsh')` (`:61-63`).
- `resolveDshHome(configured?, env = process.env)` (`:87-92`): `configured ?? (non-blank $DSH_HOME) ?? ~/.dsh`, then `resolve(expandHomePath(...))`.
- `dshHomePath(...segments)` (`:98-100`) reads **live `process.env` each call** — `DSH_HOME` must be set before boot.

| Path | Purpose |
|---|---|
| `$DSH_HOME` | Root; default `~/.dsh` |
| `$DSH_HOME/profiles/<name>/` | `package.json` (`dsh.profile.bundles`), empty-array `cordis.patch.yml`, `pnpm-workspace.yaml` (`nodeLinker: hoisted`, `autoInstallPeers: false`), `node_modules/`, `cordis.yml`, `.plugin-manager/run.json` |
| `$DSH_HOME/cordis.patch.yml` | Home-level patch layer (outranks per-profile) |
| `$DSH_HOME/sessions/` | `session-persistence-jsonl` root (`root: !!js dshHomePath('sessions')`), keyed by `projectKey(cwd)` |
| `$DSH_HOME/storages/` | `storage-json` root (`root: !!js dshHomePath('storages')`, mkdir 0o700, no default on purpose). The workspace registry persists a `workspaces` table here as a `<unit>.json` file — **the exact file name `workspace.json` is UNVERIFIED** |
| `$DSH_HOME/.credentials.yaml` | `@deepseek-ai/dsh-credentials-local`; layered: inherited env (read-only, wins) > `$DSH_HOME/.credentials.yaml` > `<cwd>/.env` > `$DSH_HOME/.env`. Holds API keys **and the browser-session HMAC secret** |
| `$DSH_HOME/.anonymous-user-id` | `packages/identity/anonymous-user-id/src/index.ts:29` `ANONYMOUS_USER_ID_FILE_NAME = '.anonymous-user-id'`; best-effort write, so a read-only home is tolerated |
| `$DSH_HOME/cache/` | `dshCachePath` |

Telemetry row (`base/cordis.patch.yml:204-217`): `session-telemetry-otel`, mode `process.env.DSH_TELEMETRY_MODE || 'FEEDBACK_ONLY'`, url `DSH_TELEMETRY_OTLP_URL ?? 'https://harness-telemetry.deepseeksvc.com/v1/logs'`, `shutdownTimeoutMillis: 3000`. (There is no separate telemetry nonce file; identity is the anonymous-user-id file. A `nonce` field may exist inside the session telemetry payloads — **UNVERIFIED**.)

**Container must be writable/persistent**: `$DSH_HOME` itself (or sub-mounts for `profiles/`, `sessions/`, `storages/`, `.credentials.yaml`, `cordis.patch.yml`, `.anonymous-user-id`, `cache/`) **plus the workspace/cwd** (agent file edits, and the `projectKey(cwd)` that names session dirs). A read-only `$DSH_HOME` tolerates only the `.anonymous-user-id` write failing.

---

## Q9. Signals / exit

`apps/cli/src/process-shutdown.ts`:
- `PROCESS_SHUTDOWN_TIMEOUT_MS = 5_000`.
- `createProcessShutdown(dispose)`: `shutdown(code)` coalesces and exits naturally (`process.exitCode = code`) after dispose; `interrupt(code)` force-exits after dispose, and if a shutdown is already pending force-exits immediately. A timer arms a force-exit after 5 s. Repeated SIGTERM while pending → immediate force exit.
- `profile-boot.ts:266-281`: `createProcessShutdown(dispose)`; `signalShutdown` AbortController; `process.on('SIGTERM', () => interrupt(0))` (comment: "SIGTERM … exits 0 on every surface"); `process.on('SIGINT', () => interrupt(130))`; `installFailLoud`.
- Subprocess tree: `packages/subprocess/subprocess-local/src/spawn.ts:471` `detached: platform !== 'win32'`; POSIX process-group signalling (`:127`) and reap promises (`:86`) — the app tree owns its own descendant reaping.
- **PID 1**: no special handling; PID 1 gets no default signal dispositions and does not reap orphans. dsh reaps its own children, but a container should still use `--init`/`tini` for stray grandchildren and correct signal forwarding. **Drain budget is 5 s** before force-exit.

---

## Q10. Plugin installation

`apps/cli/src/plugin.ts` + `packages/boot/plugin-manager/src/operations.ts`:
- `dsh plugin --profile <name> <pnpm args…>`: resolves/creates `$DSH_HOME/profiles/<name>`, locks `package.json` (`withFileLock`), and on first use `initProfile(dir, PROFILE_TEMPLATES[profile]?.bundles ?? DEFAULT_PROFILE_BUNDLES)`.
- `runPluginCommand({profile, installAnchor: INSTALL_ANCHOR, cwd: process.cwd()}, args, {execution:'cli', outputBytes:16384, lockWaitMs:120000, lookupTimeoutMs:120000, …})` forwards args verbatim to pnpm **in the profile directory**.
- **node_modules live at `$DSH_HOME/profiles/<name>/node_modules`** (pnpm `nodeLinker: hoisted`, `autoInstallPeers: false`).
- Exit code **127** → `pnpm was not found; install pnpm and make it available on PATH.`
- **Peer/version enforcement** (`plugin-compatibility.ts`): `checkPluginCompatibility(name, manifest, exemptions, runtimeVersion)` checks every `@deepseek-ai/dsh` / `@deepseek-ai/dsh-*` peer against the runtime version; prereleases participate; `workspace:^`/`~`/`*` refer to the current runtime; other invalid ranges are incompatible; exemptions are exact `plugin@version` → exact runtime versions; error text references `dsh plugin allow-version` (exit code 101). A `versionCommand` sub-command handles `allow-version` / `revoke-version` / `version-exemptions` (`--accept-risk`, `--dsh-version`).
- Install bookkeeping: `INSTALL_COMMANDS` detection; `namedSpecManifest` (path read from disk; registry via `pnpm view <spec> name version peerDependencies --json`; git/tarball judged after install); `recordRun`/`activeRecordedRun` at `<profile>/.plugin-manager/run.json` (stale-run guard); `bundleComponentManifests` reads each bundle's `dsh.bundle` patches, collects row `name` values, and checks installed component manifests' peers after pnpm; `saveManifest` writes the profile `package.json` with mode 0600; `reconcileBundleList` filters removed/uninstalled bundles and adds new ones; a failure path restores `package.json`/`pnpm-lock.yaml`/`node_modules`.
- `dsh plugin` warnings from `readProfileCompatibility`; git+ specs may need `allowBuilds` in `<profile>/pnpm-workspace.yaml`.
- **Adding an external plugin row does NOT require a fork**: the profile's `cordis.patch.yml` supports an `insert` row (`PatchOptions = {id?, insert?: EntryOptions[], name?, config?, group?, disabled?, inject?, intercept?, isolate?, [key:string]: any}` from `@deepseek-ai/cordis-plugin-include/lib/types/index.d.ts:27-38`). An inserted `name` may be a package name or a path; absolute/`./`/`../` names are rewritten to `file://` URLs anchored beside the patch file (`anchorInsertedPluginNames`). Bundles installed by name are recorded in the profile `package.json` `dsh.profile.bundles`.

---

## Ten most decision-relevant facts for an upstream-tracked container behind a public proxy

1. **The CLI refuses `--host 0.0.0.0` but the webserver schema allows it.** Bind all interfaces via a patch overlay on row `webserver` setting `host: 0.0.0.0` (restate `port`, `compression`, `compressionLevel`, `compressionThresholdBytes`). `startup.ts:74-76`; `webserver/src/index.ts:126-132`.
2. **A TLS-terminating proxy must preserve `Host` AND the FQDN must be in `trustedHosts`.** The fence requires either a loopback hostname or a trusted authority, and if `Origin` is present it must match `Host` exactly. Set the connection row `trustedHosts` to include the public FQDN (keep the `!!js ctx.webRuntime.trustedHosts` expression and concatenate). `api-request-trust.ts:91-118`.
3. **Do not rewrite Host to `127.0.0.1:3080`** — the browser's `Origin` then fails the strict equality check (403). Host and Origin must both be the public FQDN. `api-request-trust.ts:110-116`.
4. **The auth cookie is authority-dependent and has no `Secure` flag.** Cookie name/HMAC payload bind to `Host`; any change of the forwarded Host between the token GET and later requests yields 401. Path is `/` and must be rewritten to the mount for a subpath deployment. `browser-auth.ts:106-108,120-123`.
5. **Subpath works only with a prefix-stripping proxy** that forwards upgrades and rewrites `Path=/` cookies; the client uses `document.baseURI` from the injected `<base href="./">`, and supported entries are `/mount/` and `/mount/index.html`. `frontend-static/src/index.ts:117-120`; `apps/web/tests/prefix-proxy.ts`.
6. **The launch token is per-process and not persisted**; cookies survive restarts via the HMAC secret in `$DSH_HOME/.credentials.yaml`. Supervisors must re-open the newly printed tokenized URL after each restart. `browser-auth.ts:20,52-58,161-178`.
7. **Default permission mode is `workspace-write` and the sandbox may be unusable in a container.** With no `bwrap` and no Landlock the app refuses confined commands (`SANDBOX_UNAVAILABLE`). Either install bubblewrap or set `DSH_PERMISSION_MODE=danger-full-access` (also disables approvals) via env and/or the `sandbox-policy` patch. `base/cordis.patch.yml:228-247`; `sandbox/src/index.ts:132-145`.
8. **State lives under `$DSH_HOME` (default `~/.dsh`) and must be a writable persistent volume**: `profiles/`, `sessions/`, `storages/`, `.credentials.yaml`, `cordis.patch.yml`, `.anonymous-user-id`, `cache/` — plus the workspace cwd. `home-paths/src/index.ts:87-100`; config rows above.
9. **Signal drain budget is 5 s, and PID 1 behavior is not special-cased** — run with `--init`/tini in the container so signals forward and orphans are reaped. `apps/cli/src/process-shutdown.ts`; `profile-boot.ts:280-281`.
10. **Everything configurable is a Cordis patch layer, so upstream tracking needs no fork**: bundle layer → profile `cordis.patch.yml` → `$DSH_HOME/cordis.patch.yml` → `--patch`; a patch replaces the whole row `config`; external plugins are added with an `insert` row. `profile-boot.ts:181-209`; `app-boot/src/index.ts:315-356`.

---

## REMAINS UNVERIFIED

- **Exact `workspace.json` filename** under `$DSH_HOME/storages/` — the storage-json root holds whole-unit `<unit>.json` or per-record trees; the literal `workspace.json` was not seen in the source.
- **Whether any telemetry nonce file exists** beyond `.anonymous-user-id` (the `session-telemetry-otel` row was inspected but not its payload identity internals).
- **Whether `0.0.0.0` binding actually works end to end at runtime** — verified only by schema and the patch mechanism; no server was started (read-only mandate).
- **Whether any official package injects `globalThis.__DSH_TRANSPORT__` into served pages** — evidence says no (only `apps/web/src/main.ts` for the static desktop shell and a webworker-runtime client); a served page uses `document.baseURI`.
- **Pangolin-specific behavior** (header rewriting, cookie handling, WebSocket forwarding) was not inspected — only DSH's own proxy-contract fixture and ADR.
- **Container base-image specifics** (whether bubblewrap/Landlock are available in the intended runtime) were not tested.
- **`dsh plugin` on a host without pnpm** and the exact profile repair path under a container were read but not executed.

*(End of report. All findings are from static reading of the checkout at commit `477b4f420553e8a52c2fbccc464d7561b239c443`; no files were modified, no processes started.)*
