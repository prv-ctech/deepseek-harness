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
| `DSH_IMAGE` | `ghcr.io/prv-ctech/deepseek-harness:latest` | Image Compose runs; set the `-chrome` tag for the Chrome variant, `-plus` for the toolchain variant |

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

## The `-plus` image

`ghcr.io/prv-ctech/deepseek-harness-plus` is **the `-chrome` image plus one
layer**. `INSTALL_PLUS=true` implies `INSTALL_CHROME=true` by reading both
arguments in the same condition, so the browser is not installed twice and the
two variants cannot drift into shipping different ones. Same entrypoint, same
patch, same hardening, same ports, same state volume — switching is one
variable:

```sh
DSH_IMAGE=ghcr.io/prv-ctech/deepseek-harness-plus:latest docker compose up -d
```

On Unraid, set *Repository* to `ghcr.io/prv-ctech/deepseek-harness-plus:latest`.

It exists for one reason: **plugins and tasks can detect these tools instead of
downloading them into the state volume on every deployment**, which is the same
argument the `-chrome` image makes about a browser. Three additions:

### Python

`python3` 3.11, `pip` 23.0, `python3-venv` and `python3-dev`. Plugins are npm
packages, but nearly everything they shell out to — analysis scripts, a
decompiler's helper, a format converter — is Python, and the usual failure mode
in the base image is exactly this: a plugin that probes for `python3`, finds
nothing, and degrades.

Two constraints are real, so read this before you `pip install` something:

- **Debian's Python is PEP 668 externally-managed**, so a plain `pip install`
  is refused. The image sets `PIP_BREAK_SYSTEM_PACKAGES=1`, which is what makes
  the agent's own `pip install` calls work at all. It is the only environment
  variable the variant adds, and it is inert in the base and `-chrome` images,
  which ship no pip.
- **The sandbox still decides where a package can land.** Under the default
  `workspace-write` posture, Landlock grants writes only under `/workspace` and
  `/tmp`, so a system-wide install into
  `/usr/local/lib/python3.11/dist-packages` cannot succeed from inside a tool
  call. `pip install --user` is the install that works from in there, and it
  lands under `$HOME`, which is the state volume. Anything that must outlive a
  session should be preinstalled — which is why `androguard` is baked in.

### rtk

[rtk](https://github.com/rtk-ai/rtk) is a single static Rust binary that
rewrites a command and filters its output, cutting 60–90% off the token cost of
common dev commands. `rtk` v0.50.0 is installed at `/usr/local/bin/rtk`, from
the release's **musl tarball** with its sha256 pinned in the Dockerfile — not
from the `.deb` the same release publishes, which declares `libc6 (>= 2.39)`
while bookworm ships 2.36 and would fail the build.

The contract plugins depend on is `rtk rewrite "<command>"`: exit **3** with
the rewritten command on stdout when there is an equivalent, exit **1** with
nothing when there is not. The smoke test asserts both, because rtk's own
`--help` says it "exits 0" and that is not what it does.

> **`dsh-pwsh-rtk-rewrite` does not activate on this image.** That plugin
> replaces the **PowerShell** executor, and its own `cordis.patch.yml` disables
> it on non-Windows (`disabled: !!js process.platform !== 'win32'`), so on Linux
> it is a deliberate no-op rather than a broken install. What the image
> guarantees is the other half: `rtk` is on `PATH` for the agent and for any
> plugin that probes for it, so `rtk read`, `rtk grep`, `rtk ls` and `rtk git …`
> work from a shell call today, and a bash-executor rewrite plugin would work
> against them unchanged.

### Android reverse engineering

Decompile an APK, read what is inside it, rebuild and resign it:

| Tool | What it does |
| --- | --- |
| `jadx` 1.5.6 | DEX → readable Java sources; the main tool for "what does this app do" |
| `apktool` 2.7.0 | resources, manifest and smali, plus `apktool b` to rebuild an APK |
| `smali` / `baksmali` 2.5.2 | DEX ↔ smali round trip, for when jadx's output is not enough |
| `enjarify` 1.0.3 | DEX → `.jar`, in pure Python — bookworm packages no `dex2jar` |
| `aapt`, `aapt2` | dump the manifest, badging and the resource table |
| `dexdump` | disassemble a raw `.dex` with no APK around it |
| `apksigner`, `zipalign` | sign and align a rebuilt APK |
| `androguard` 4.1.4 | scriptable APK/DEX analysis: manifest, certificates, classes, strings |

```sh
jadx -d out/ app.apk          # Java sources
apktool d -f app.apk          # manifest, res/, smali/
apktool b dist/               # rebuild → dist/app/dist/app.apk
zipalign -p 4 in.apk out.apk && apksigner sign --ks key.jks out.apk
androguard axml app.apk       # manifest as XML
```

Three things about this set are not obvious, and each was verified against a
real APK rather than assumed:

- **Debian puts the build tools off `PATH`.** `aapt`, `aapt2`, `dexdump`,
  `apksigner` and `zipalign` install to
  `/usr/lib/android-sdk/build-tools/debian/` with no `/usr/bin` entry and no
  `update-alternatives`. The image symlinks them into `/usr/local/bin`; without
  that they exist and cannot be run.
- **apktool needs its framework, and this image's `XDG_DATA_HOME` breaks it.**
  apktool 2.7 reads its framework from `$XDG_DATA_HOME/apktool/framework`, but
  Debian's `apktool` package links it into `~/.local/share/…`. This image points
  `XDG_DATA_HOME` at the state volume, so with no help apktool creates a
  **zero-byte** `1.apk` and then dies with `Could not load resources.arsc`. The
  entrypoint creates the link at the path apktool actually reads, and warns
  instead of failing when the state directory is not writable.
- **One JRE serves all of them.** `openjdk-17-jre-headless` (188 MB installed)
  is what jadx, apktool, smali and apksigner run on. jadx's upstream launcher
  is installed unmodified — its default JVM flags are accepted by Java 17.

`androguard` is preinstalled on purpose: it is the only tool here that answers
structured questions about an APK from a script, and a runtime `pip install` of
it could not work under the default sandbox anyway (see Python above).

**What this variant is not**: it is not the Android SDK. There is no `adb`, no
Gradle, no platform or NDK, and no `d8`/`dx` — bookworm packages none of them —
so this is a decompile/read/rebuild toolchain, not a place to build an app from
source.

**Cost**: roughly 400–500 MB over the `-chrome` image — the JRE (188 MB),
jadx (~80 MB), `android-framework-res` (~45 MB), Python, androguard's
dependency tree, and the Java libraries apktool pulls.

**The hardened runtime is unchanged.** Every one of these tools reads the APK and
writes under `$HOME` or the workspace; nothing execs from `/tmp`, so
`--read-only`, `--cap-drop ALL`, `no-new-privileges` and a `noexec /tmp` all
keep working. The smoke test runs jadx, rtk, androguard and a
`pip install --dry-run` as the unprivileged `PUID` under exactly those flags.
The one claim *not* exercised there is a full `apktool d` decode inside the
hardened container: its framework link is asserted directly instead, and the
JVM and Python checks already cover that posture.

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

Images are `linux/amd64` and published as three packages —
`ghcr.io/prv-ctech/deepseek-harness`,
`ghcr.io/prv-ctech/deepseek-harness-chrome` and
`ghcr.io/prv-ctech/deepseek-harness-plus`. All three come from the same
Dockerfile: the Chrome one is the same build with
`--build-arg INSTALL_CHROME=true`, the `-plus` one adds
`INSTALL_PLUS=true` (which implies Chrome), and each package carries its own
recipe label, so none of them can mask a rebuild of another.

The Docker build can copy only `Dockerfile`, `docker-entrypoint.sh`,
`proxy.patch.yml`, and `fix/owns-host.mjs` from its context. Local `.env` files,
credentials, runtime state, and research notes are excluded by `.dockerignore`.

```sh
# build locally (INSTALL_CHROME=true for -chrome, INSTALL_PLUS=true for -plus)
docker build --build-arg DSH_VERSION=0.1.7-rc.2 -t dsh .

# pin an exact release
docker run -d -p 3080:3080 -v dsh-state:/home/node/.dsh \
  ghcr.io/prv-ctech/deepseek-harness:0.1.7-rc.2
```

## Layout

```
Dockerfile              image build; the base package, the -chrome variant when
                        built with INSTALL_CHROME=true, and the -plus variant
                        when built with INSTALL_PLUS=true
docker-entrypoint.sh    ownership + PUID/PGID drop, apktool's framework link,
                        then exec dsh
proxy.patch.yml         the launch layer: 0.0.0.0 bind, plugin insert
fix/owns-host.mjs       restores remote Settings, prints the public URL
compose.yaml            reference deployment behind Pangolin
scripts/published-recipe.sh   recipe label lookup used by the workflow
docs/PLAN.md            the research and decisions behind this design
docs/research/          audits of upstream 0.1.7-rc.2 and three related repos
```

## Upgrading upstream

Nothing to merge. When a new RC is published the workflow builds, smoke-tests
(version equality, PID-1/uid drop, the launch-token gate, a real headless
launch under the hardened flags for `-chrome` and `-plus`, and — for `-plus` —
Python, rtk's rewrite contract, every Android tool on `PATH`, and a real jadx
and apktool decode of a real APK) and pushes it. The
seams this repo uses are upstream's own, so they move with it. The one thing to
re-check on a major release is the `webserver` row's config keys: a patch layer
replaces that row's whole config, and a key upstream adds must be restated in
`proxy.patch.yml` or the row fails schema validation at boot.
