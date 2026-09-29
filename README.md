# deepseek-harness

Container images for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`)
that work behind an external reverse proxy.

Upstream `dsh web` is loopback-only by design: the CLI refuses `--host 0.0.0.0`
(`--host 0.0.0.0 is intentionally not supported yet for safety`), the printed URL
is always `http://127.0.0.1:<port>`, and the remote Settings page turns read-only
off loopback. That is correct for a desktop tool and useless for a container that
a reverse proxy has to reach.

This repo ships the smallest complete change that fixes that, and nothing else.
**Upstream is not forked and not patched** — every change goes through
mechanisms the published package supports, so a new release is a rebuild, not a
merge.

| Problem | Fix | Mechanism |
| --- | --- | --- |
| Refuses to bind anything but loopback | `proxy.patch.yml` sets the webserver row to `0.0.0.0` | upstream `--patch` layer (its documented opt-in) |
| `/api` rejects the public hostname (403) | `--trusted-host $DSH_PUBLIC_HOST` | upstream CLI flag |
| Settings read-only behind a proxy | `fix/owns-host.mjs` exports `__DSH_TRANSPORT__ = { ownsHost: true }` | upstream `webserver/index-inject` event |
| Operator cannot find the URL | the same plugin prints `https://…/?token=…` | public `connection.authenticatedUrl()` API |

## Quick start

The GHCR image is private. On each Docker host, sign in as a GitHub account with
access to the package before the first pull or update. Use a personal access
token (classic) with `read:packages` as the password:

```sh
docker login ghcr.io -u prv-ctech
# paste the token at Docker's password prompt
```

Keep the token on the Docker host; do not put it in `.env`, Compose, or the Unraid
template. [GitHub's registry guide](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry)
documents the token scope and login. Docker stores login credentials in its
[configured credential store](https://docs.docker.com/reference/cli/docker/login/#credential-stores);
without one, its config file contains base64-encoded credentials. Repeat login
before an update if that host no longer has the credentials.

`DSH_PUBLIC_HOST` is required — it is the authority your browser uses, and the
image ships no default so that no deployment inherits someone else's domain:

```sh
cp .env.example .env
# edit .env: DSH_PUBLIC_HOST=your.host.name
docker compose up -d
docker logs deepseek-harness      # prints the URL to open
```

Compose reads `.env` automatically, and it is gitignored. Prefer a one-off
instead? `DSH_PUBLIC_HOST=dsh.example.com docker compose up -d` works too.

Then create the site in Pangolin with target `http://<docker-host-ip>:3080`.

## How the proxy must be configured

Pangolin (Traefik) **preserves the inbound `Host` header by default**, which is
what this image relies on: the `/api` fence compares the request's `Host` and
`Origin`, so a proxy that rewrites `Host` to `127.0.0.1` breaks the GUI with 403s.
Do not set a custom Host header for this resource.

`DSH_PUBLIC_HOST` must be the exact authority a browser uses — scheme and port
are not part of it, but a non-default port is (`example.com:8443`). It is passed
to dsh as `--trusted-host`; anything the browser addresses that is missing from
that list gets HTTP 403.

Add extra authorities (a LAN address, an alternate hostname) with
`DSH_TRUSTED_HOSTS="192.168.1.10:3080,dsh.lan"`. When the container binds
`0.0.0.0`, upstream derives the host's LAN IP literals automatically, so only
named authorities need listing.

### Security headers belong to the proxy

Upstream sends no CSP, HSTS, `X-Content-Type-Options`, or `X-Frame-Options`, and
its auth cookie is `HttpOnly; SameSite=Strict` **without `Secure`**
(`packages/client/connection/src/browser-auth.ts` — there is no config key for
it). Neither can be added from inside the process: the webserver plugin has no
response-header middleware. Add them at the proxy, e.g. a Traefik
`headers` middleware with `forceSTSHeader`, `contentTypeNosniff`, and
`referrerPolicy`. HSTS is what keeps the `Secure`-less cookie off plaintext
requests, so it is not optional.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `DSH_PUBLIC_HOST` | *(required)* | Authority browsers use; becomes `--trusted-host` and the printed URL |
| `DSH_TRUSTED_HOSTS` | *(empty)* | Extra comma-separated authorities for the `/api` fence |
| `DSH_PERMISSION_MODE` | `workspace-write` | Sandbox mode: `read-only`, `workspace-write`, `danger-full-access` |
| `PUID` / `PGID` | `1000` / `1000` | Owner of the state volume and `/workspace` |
| `DSH_HOME` | `/home/node/.dsh` | State directory (mount a volume here) |
| `DSH_WORKSPACE_DIR` | `/workspace` | Directory chowned at start |
| `DSH_BIND` / `DSH_PORT` | `0.0.0.0` / `3080` | Host side of the published port |
| `DSH_WORKSPACE` | `./workspace` | Host path mounted at `/workspace` |
| `DSH_IMAGE` | `ghcr.io/prv-ctech/deepseek-harness:latest` | Image Compose runs; set the `-chrome` tag for the Chrome variant |

### The sandbox

It stays **on** (`workspace-write`): tools may read anywhere but write only
inside `/workspace` and `/tmp`, and commands that would ask for more are gated.

This is the point where most container builds fail, so the details matter. dsh
picks its confinement from a per-platform chain — on Linux `bwrap` first, then
Landlock — probing each rung and **failing closed** (`SANDBOX_UNAVAILABLE`) if
none works. `bwrap` needs namespaces that a default Docker container denies, so
relying on it produces exactly the "works on my machine" breakage this repo
exists to avoid. `node:22-bookworm-slim` has no `bwrap` at all, so the chain
falls through to Landlock, which is **unprivileged** and verified enforcing here
even under `--read-only --cap-drop ALL --security-opt no-new-privileges`:

```
$ landlock-run --probe
landlock: fully enforced
```

If your host cannot enforce either rung, dsh refuses to run tools rather than
silently running them unsandboxed. Set `DSH_PERMISSION_MODE=danger-full-access`
only if you deliberately want that.

### `--read-only` and `noexec /tmp`

The compose file runs with a read-only root filesystem; keep it if you can. It
works because every writable path is in the state volume or `/tmp`, and because
the image relocates one non-obvious cache:

dsh loads its native addons through `node-addon-native-custom-loader`, which
**copies** each prebuilt `.node` into `os.tmpdir()` and `dlopen`s it from there.
On a hardened `--tmpfs /tmp:noexec` container that fails with
`Cannot find module …/napi-v9-linux-x64-gnu/require_builtin.node` and dsh never
starts. `NARB_NATIVE_CACHE_DIR=/home/node/.dsh/cache/native` is baked in for this
reason — it points the cache at a real filesystem so you can keep `noexec /tmp`.

## The `-chrome` image

`ghcr.io/prv-ctech/deepseek-harness-chrome` is this image plus Google Chrome,
installed at the system level from Google's apt repository
(`/usr/bin/google-chrome-stable`). It exists because a plugin that drives a real
browser — `dsh-realbrowser`, or anything else that speaks CDP — otherwise
downloads a browser into the state volume, and that copy cannot run here: the
base image ships neither Chrome's shared libraries nor any font, so it fails at
`ldd` and aborts on its first page.

Everything else is identical: same entrypoint, same patch layer, same hardening,
same ports, same state volume. Switching is one variable:

```sh
DSH_IMAGE=ghcr.io/prv-ctech/deepseek-harness-chrome:latest docker compose up -d
```

On Unraid, set *Repository* to `ghcr.io/prv-ctech/deepseek-harness-chrome:latest`.

- **The image copy wins the lookup.** The plugin resolves
  `google-chrome-stable` by name from `PATH` before it considers a downloaded
  one, so `/usr/bin/google-chrome-stable` is used and the volume store becomes a
  fallback only.
- **No browser flags are added by this image.** The entrypoint passes none; the
  plugin already passes `--no-sandbox --disable-dev-shm-usage --no-first-run
  --no-default-browser-check`, plus `--remote-debugging-port` and a
  `--user-data-dir` under the state volume.
- **The hardened runtime is unchanged, and the build's smoke test exercises
  Chrome under it**: `--read-only`, `--cap-drop ALL`, `no-new-privileges` and
  `noexec /tmp` all stay. Chrome never needs to execute anything from `/tmp`;
  its only writable paths are the state volume (profile) and `/tmp`.
- **Fontconfig and a font set are installed explicitly** rather than left to
  Chrome's own dependency list. Under `--no-install-recommends` a missing
  fontconfig makes Chrome abort with
  `FATAL: SkFontMgr_FontConfigInterface.cpp Not implemented` and signal 6 on any
  page containing a `<form>` — which surfaces misleadingly as
  `WebSocket closed: 1006`. Latin-only is not enough to browse either: without
  the non-Latin families a Japanese, Korean, Chinese or Arabic page draws tofu,
  silently. So the image ships `fonts-noto-core` (Arabic, Hebrew, Devanagari,
  Thai, ~60 scripts), `fonts-noto-cjk` (Japanese, Korean, Simplified and
  Traditional Chinese), `fonts-noto-color-emoji`, plus `fonts-dejavu-core`, the
  family fontconfig's own `latin.conf` prefers. The smoke test asserts one
  coverage per package — `fc-list :lang=ja`, `:lang=ar`, `:charset=1f600` — so
  dropping a font package fails the build, not the user's page.
- **Cost and ownership**: Chrome adds roughly 150–250 MB and the font set about
  145 MB more (~89 MB of that `fonts-noto-cjk`), so budget roughly 300–400 MB
  over the base image. The Chrome version follows the image build, so upgrading
  Chrome means rebuilding the image. That is deliberate: one artefact, one
  Chrome, no per-deployment browser download.

## Running it other ways

**Rootless / explicit user** — the image pre-creates `/home/node/.dsh` and
`/workspace` owned by `1000:1000`, so Docker seeds fresh volumes with the right
ownership and `--user 1000:1000` works with no capabilities:

```sh
docker run -d --user 1000:1000 -p 3080:3080 \
  -v dsh-state:/home/node/.dsh ghcr.io/prv-ctech/deepseek-harness:latest
```

With `--user` the entrypoint skips chowning and, if the state volume is
unwritable, prints the exact host-side `chown` instead of a stack trace.

**Unraid** — use `unraid/deepseek-harness.xml` (Docker tab → Add Container →
paste, or drop it in `/boot/config/plugins/dockerMan/templates-user/`). It sets
`PUID=99`/`PGID=100` to match Unraid's usual `nobody:users` share ownership, and
leaves *Post Arguments* as a bare `web`. The entrypoint injects the patch layer
itself, and caller-supplied flags win, so the mward4-style
`web --patch … --no-open` still works if you paste it. Browsing by IP needs no
configuration; a hostname goes in *DSH Public Host*. Run the GHCR login above in
Unraid's terminal before installing or updating the container.

**Choosing the numbers**: `PUID`/`PGID` may be any uid/gid, including ones with
no passwd entry (Unraid's `99:100`). The entrypoint uses
`setpriv --clear-groups` precisely because `--init-groups` refuses unknown uids,
and dsh runs fine as a bare numeric uid as long as `HOME`, `SHELL` and `DSH_HOME`
are set — all three are.

## First login

`docker logs deepseek-harness` prints:

```
dsh web (proxy): https://dsh.example.com/?token=…
dsh web: http://127.0.0.1:3080/?token=… (LAN: http://172.17.0.2:3080/?token=…)
```

Open the first line. The token is exchanged for an authority-bound session
cookie (30 days, `HttpOnly; SameSite=Strict`) and is **rotated on every
restart**, so a 401 after a restart means: re-read the log line. A 403 means the
`Host`/`Origin` the browser sent is not in the trusted list — check
`DSH_PUBLIC_HOST` and any proxy that rewrites `Host`.

## What this image is not

- **No desktop.** The plain image ships no browser at all; the `-chrome` image
  ships Chrome and its runtime libraries, but no desktop and no noVNC. The GUI's
  browser view is a CDP screencast, not a virtual desktop.
- **Not a TLS terminator.** Put it behind a proxy that does TLS.
- **No `Secure` cookie, no security headers** — upstream cannot, so the proxy
  must. See above.

## Building and releases

`.github/workflows/build.yml` tracks upstream **release candidates only**,
starting at `0.1.7-rc.2`. It reads the version list from the npm registry rather
than the `latest` dist-tag, because those disagree: `0.1.7-rc.2` was published
while `latest` still resolved to `0.1.5-rc.3`.

Each RC is built once per recipe. The recipe hash (Dockerfile + entrypoint +
patch + plugin) is stored in the image label
`org.opencontainers.image.dsh-recipe`; a schedule run rebuilds a version only
when its image is missing or carries a stale hash, so improving this repo
reaches versions that were already published. `:latest` follows the newest
tracked RC and is moved by copying the manifest that already passed the smoke
test.

Images are `linux/amd64` and published as two packages —
`ghcr.io/prv-ctech/deepseek-harness` and
`ghcr.io/prv-ctech/deepseek-harness-chrome`. Both come from the same Dockerfile;
the Chrome one is the same build with `--build-arg INSTALL_CHROME=true`, and each
package carries its own recipe label, so neither can mask a rebuild of the other.

The Docker build can copy only `Dockerfile`, `docker-entrypoint.sh`,
`proxy.patch.yml`, and `fix/owns-host.mjs` from its context. Local `.env` files,
credentials, runtime state, and research notes are excluded by `.dockerignore`.

```sh
# build locally (add INSTALL_CHROME=true for the -chrome variant)
docker build --build-arg DSH_VERSION=0.1.7-rc.2 -t dsh .

# pin an exact release
docker run -d -p 3080:3080 -v dsh-state:/home/node/.dsh \
  ghcr.io/prv-ctech/deepseek-harness:0.1.7-rc.2
```

## Layout

```
Dockerfile              image build; the base package, and the -chrome variant
                        when built with INSTALL_CHROME=true
docker-entrypoint.sh    ownership + PUID/PGID drop, then exec dsh
proxy.patch.yml         the launch layer: 0.0.0.0 bind, plugin insert
fix/owns-host.mjs       restores remote Settings, prints the public URL
compose.yaml            reference deployment behind Pangolin
scripts/published-recipe.sh   recipe label lookup used by the workflow
docs/PLAN.md            the research and decisions behind this design
docs/research/          audits of upstream 0.1.7-rc.2 and three related repos
```

## Upgrading upstream

Nothing to merge. When a new RC is published the workflow builds, smoke-tests
(version equality, PID-1/uid drop, the launch-token gate, and — for the `-chrome`
package — a real headless launch under the hardened flags) and pushes it. The
seams this repo uses are upstream's own, so they move with it. The one thing to
re-check on a major release is the `webserver` row's config keys: a patch layer
replaces that row's whole config, and a key upstream adds must be restated in
`proxy.patch.yml` or the row fails schema validation at boot.
