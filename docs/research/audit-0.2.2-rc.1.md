# Audit against dsh 0.2.2-rc.1

Date: 2026-11-04. Repo HEAD `dbb2dc1` (image default `DSH_VERSION=0.2.1-rc.2`).
Method: both npm releases (0.2.1-rc.2, 0.2.2-rc.1) installed with their full
dependency trees and read as shipped; upstream READMEs and release notes; a
survey of real-browser options. Every "still needed" verdict below cites the
0.2.2-rc.1 file that proves it.

npm tags today: `latest` 0.2.1-rc.5, `next` 0.2.2-rc.1. There are no final
releases, only RCs.

## 1. Each workaround in this repo, against 0.2.2-rc.1

| Workaround | Verdict | Evidence |
|---|---|---|
| `--host <container IP>` via `bin/dsh-bind-host` | **Still needed** | Wildcard still rejected (`dsh-web-app` README, "Binding all network interfaces is not supported"). Upstream's own container example does the same thing with `hostname -i`. |
| `--trusted-host $DSH_PUBLIC_HOST` | **Still needed** | "Advertisement grants no trust: the browser-visible authority must also be named with `--trusted-host`." |
| `fix/owns-host.mjs` job 1: `__DSH_TRANSPORT__.ownsHost` to keep Settings writable | **Still needed** | `dsh-client-connection/lib/client.browser.js:1424`: `isLoopback: transport?.ownsHost === true \|\| … isLoopbackHostname(…)`; `dsh-client-ui-settings-general/lib/client.js:1403` still builds the settings store only when `isLoopback`. |
| `fix/owns-host.mjs` job 2: print `https://$DSH_PUBLIC_HOST/?token=…` | **Obsolete** | Upstream `--public-url` (in 0.2.1-rc.2 already, and 0.2.2-rc.1) prints and opens `authenticatedUrl(publicUrl)` (`dsh-web-app/lib/index.js:146-162`). It also fixes `DSH_WEB_URL`, which the agent sees: today that variable points at the container IP. |
| `proxy-wildcard.patch.yml` + entrypoint version gate | **Can retire** | Only for 0.2.0-rc.2. Retirement needs `MIN_VERSION` raised to `0.2.1-rc.1` in the workflow. |
| `NARB_NATIVE_CACHE_DIR` | **Still needed** | `node-addon-native-custom-loader` is still 0.1.9 in 0.2.2-rc.1 and still copies addons into `os.tmpdir()`. |
| `webserver/index-inject` seam | **Still present** | Used by 10 upstream packages in 0.2.2-rc.1. |
| pnpm in image | Not re-verified | Plugin management still exists. Keep it. |

New upstream options this image does not use yet:
- `--public-url`, which replaces job 2 above.
- `--tls-cert` / `--tls-key` for HTTPS on the listener. Not needed behind Pangolin.
- `printUrl`, `openBrowser` and `surfaceContext` config fields.

## 2. Cleanup (applied, uncommitted)

1. Entrypoint passes `--public-url "https://$DSH_PUBLIC_HOST/"` unless the caller passes one. `owns-host.mjs` keeps only the `ownsHost` half. CI smoke now asserts the `dsh web: https://smoke.example/?token=` line.
2. `MIN_VERSION` is now `0.2.1-rc.1`, which has `--public-url` (checked in its `startup.js`). Removed with it:
   - `proxy-wildcard.patch.yml`
   - its `COPY`/`chmod`, `.dockerignore` entry, recipe-hash entry and push path
   - the entrypoint's version gate
   - the README and Unraid text about it
3. `ARG DSH_VERSION` default is now `0.2.2-rc.1`, and the README examples match.
4. Fixed the stale "real browser" and "-chrome" text.
5. Moved `# syntax=docker/dockerfile:1` to line 1.
6. `dsh-bind-host` now checks `DSH_BIND_HOST` before the route probe.
7. The entrypoint warns when `--port` is not 3080, because the healthcheck probes 3080. The README says so too.

Verified without Docker (no daemon in this environment):
- The entrypoint, run with a stub `dsh`, builds the expected arguments for 5 cases.
- Real dsh 0.2.2-rc.1, started with those exact flags and this patch layer:
  - prints `dsh web: https://dsh.example.com/?token=…`
  - answers 401 without a token
  - exchanges the token for a cookie through `Host: dsh.example.com` (303)
  - serves an index carrying `__DSH_TRANSPORT__ { ownsHost: true }`

Not verified: an image build, and the CI smoke run.

## 3. Why the Web browser panel "refuses to connect"

Package: `@deepseek-ai/dsh-client-ui-sidebar-browser`.

- Web uses a plain sandboxed `<iframe>`, and that is a design decision: "The package does not proxy or probe remote pages." Any site that sends `X-Frame-Options` or CSP `frame-ancestors` is blocked by your own browser. The per-tab sandbox toggle does not help with this, and neither does any config setting. The package has no plugin configuration.
- Desktop uses an Electron `<webview>`, which is not subject to frame headers.
- The carrier is chosen in `client.js:1771`: `globalThis.dshDesktop?.protocolVersion === 1`. Faking it is not workable, because the Desktop path calls `document.createElement("webview")` and drives Electron-only methods (`loadURL`, `canGoBack`, guest leases). Emulating that in Chrome or Firefox would mean monkey-patching the DOM.
- Upstream's answer is the toolbar's "Open in system browser" button.

## 4. Options for a real browser

| # | Option | Effort | Notes |
|---|---|---|---|
| A | **Sidecar Chromium with a web viewer** (e.g. m1k1o/neko, Apache-2.0), published through Pangolin on its own subdomain. The agent attaches to the **same** Chromium through upstream's `@deepseek-ai/dsh-experimental-browser-use-chrome-devtools-mcp` (`mode: attach`, `endpoint: http://<sidecar>:9222`). | Low: compose service + profile patch, no new code | Closest to ChatGPT-agent: one browser that you and the agent share, with logins persisting. You can view it in a normal tab, or inside the dsh Browser tab if the viewer allows framing (unverified for neko). This image redistributes no codecs, so it avoids the GPL problem that stopped the Selkies work. |
| B | **Custom client plugin**: a new right-sidebar tab type that renders a CDP `Page.startScreencast` stream from a host plugin and forwards input. | Medium–high | Feels native and needs no extra subdomain. Requires building a client bundle against unstable `0.2.x` client APIs. |
| C | Header-stripping proxy (Scramjet / Ultraviolet) | High, ongoing | Not recommended. It breaks logins, SPAs and service workers, and needs constant maintenance. The panel also rejects the DSH origin, so the proxy would need its own subdomain anyway. |

Security for A:
- CDP has **no authentication**. Port 9222 must stay on the internal Docker network: never publish it, and never route it through Pangolin.
- Put the viewer behind Pangolin auth.
- The agent's `mode: attach` session can read every cookie in that browser.

### Decision: B (plugin) + headless Chromium sidecar + upstream CDP attach

The deciding facts:

| Fact | Effect |
|---|---|
| Neko streams over **WebRTC only**: `NEKO_WEBRTC_EPR`/`UDPMUX`/`TCPMUX`, no WebSocket fallback found in docs or repo. | Media needs a UDP range or a mux port that bypasses Pangolin's HTTPS path. Remote use via Pangolin is the user's actual setup, so A fails exactly there. |
| Neko has no CDP flag or env var. Chromium flags are hardcoded in `apps/chromium/supervisord.conf`, so supporting CDP means overriding the whole file under `/etc/neko/supervisord/`. Chromium ≥111 also needs `--remote-allow-origins`. | The agent-sharing half of A is an undocumented override. |
| Neko's default credentials are `admin`/`neko` (multiuser provider), and its frame headers are unverified. | A brings a second login and another thing to harden. |
| dsh's webserver lets plugins `registerUpgrade(route)` WebSocket paths (`dsh-host-webserver` README). | A plugin's screencast stream rides dsh's own origin, through the same Pangolin HTTPS resource, with no extra port or subdomain. |
| Third-party plugins ship web client code: `dsh.client` with `platform: web` (`dshmarket` does it), and client plugins can register right-sidebar tab types (`ctx.sidebarRightTabs.register`). | B is a supported extension path, not a hack. |
| Upstream `dsh-experimental-browser-use-chrome-devtools-mcp` supports `mode: attach` with `endpoint`. | The agent drives the same Chromium with no new code. |

Shape of B:
- Sidecar: `chromedp/headless-shell` (MIT) with CDP on the internal Docker network only.
- A dsh host plugin that bridges CDP `Page.startScreencast` and `Input.dispatch*` over a `registerUpgrade` WebSocket. It must authenticate the upgrade with dsh's session cookie and fence.
- A client plugin that adds a "Remote browser" sidebar tab: canvas, address bar, take-control toggle.

Costs and risks of B:
- Real code to write and maintain.
- 0.2.x plugin APIs break between minors. `dshmarket` pins peer ranges per minor.
- Upgrade routes get a raw socket with no auth applied. Using the connection service's check for this is unverified.
- Screencast is JPEG frames: fine for browsing, not for video.

When A would win instead: viewing only on the LAN, where WebRTC ports are reachable directly.
