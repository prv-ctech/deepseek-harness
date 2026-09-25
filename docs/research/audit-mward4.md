# Audit — mward4/deepseek-harness

**Repo:** `/tmp/dsh-research/mward4` (gitea.milesward.dev/mward4/deepseek-harness)
**Commit:** `c398febf0fa0794a33c1e82de6e89c7bd0dbc058` ("Default the workspace doctor to repair")
**License:** MIT (Copyright (c) 2026 Miles Ward) — `LICENSE:1-21`. Build tooling MIT; dsh itself MIT by DeepSeek AI (`README.md:480-484`).
**Method:** read-only inspection, no edits, no builds, no container runs.
**Context of this audit:** we are building a NEW image tracking DSH **0.1.7-rc.2** for a public FQDN behind Pangolin (external TLS terminator), no loopback-only assumptions. mward4 `:latest` still tracks **0.1.5-rc.2** (`README.md:35`, `README.md:283`; `Dockerfile:18` default `0.1.5-rc.2`).

Legend: every claim carries `file:line`. Anything I could not establish from the repo is marked **UNVERIFIED** in §11.

---

## 1. Build provenance

| Fact | Evidence |
|---|---|
| Base image | `node:22-bookworm-slim` (`Dockerfile:13`; CI env `BASE_IMAGE` `sync-upstream.yml:48`) |
| Base pinning | **Not pinned by digest in the Dockerfile.** The tag is floating at build time; the *resolved* digest is captured into a label `dev.milesward.base-digest` (`Dockerfile:90`, `Dockerfile:109`; CI resolves it at `sync-upstream.yml:102-103`) | 
| DSH install | `npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" "pnpm@${PNPM_VERSION}"` from registry.npmjs.org, then `npm cache clean --force` (`Dockerfile:33-34`) |
| Version pinning | `ARG DSH_VERSION=0.1.5-rc.2` (`Dockerfile:18`) is only the **local-build default**; CI passes every version explicitly (`Dockerfile:16-17`, `sync-upstream.yml:194-196`) |
| pnpm | `ARG PNPM_VERSION=12.3.4` (`Dockerfile:22`); CI always passes `pnpm dist-tags.latest` (`sync-upstream.yml:100`, `:174`). Deliberately a pinned global, **not corepack**, because corepack resolves/downloads at runtime into a root-owned cache outside the state volume (`Dockerfile:28-32`) |
| Extra packages | `ca-certificates`, `git`, `--no-install-recommends`, apt lists removed (`Dockerfile:24-26`). **No **`zstd`** binary, no tini, no buildx tooling** |
| Image size drivers | node_modules layer is the driver: README says dsh's dependency layer passed Cloudflare's 100 MB request cap at `0.1.6-alpha.2` (`sync-upstream.yml:19-22`, `README.md:429-433`). CI re-compresses uncompressed daemon layers with gzip before push (`sync-upstream.yml:253-256`) — without it "dsh's 500 MB raw layer would reach the registry and every pull would be 4x larger". So the uncompressed dsh layer is ~500 MB |
| Provenance labels | `org.opencontainers.image.{title,description,version,revision,created,source,url,licenses}` plus `dev.milesward.{dsh-version,pnpm-version,base-digest,ci-run,recipe-hash}` (`Dockerfile:99-111`) |
| **Multi-arch** | README claims `linux/amd64` and `linux/arm64` (`README.md:165`). **The CI does not build arm64.** No `buildx`, no QEMU, no `--platform` on `docker build` (`sync-upstream.yml:194-202` builds on `ubuntu-latest` native amd64). The one `--platform linux/amd64` at `sync-upstream.yml:258` is a regctl *copy filter* for an index that already exists. ⇒ the arm64 claim is **UNVERIFIED/unsupported**, see §11 |
| Recipe hash | `sha256` of `Dockerfile docker-entrypoint.sh dsh-workspace-doctor.mjs run-as-runtime-user.sh web.cordis.patch.yml`, first 12 chars (`sync-upstream.yml:104`) |

## 2. Runtime identity

- **No `USER` directive, on purpose.** Image starts as root; entrypoint repairs ownership then `exec setpriv --reuid PUID --regid PGID --init-groups dsh "$@"` (`Dockerfile:79-81`, `docker-entrypoint.sh:172`).
- **PUID/PGID defaults** `1000`/`1000` via ENV (`Dockerfile:74-75`); entrypoint reads `PUID="${PUID:-1000}"`, `PGID="${PGID:-1000}"` (`docker-entrypoint.sh:21-22`).
- **node-user realignment** (root path only): reads `id -u node` / `id -g node`, then `groupmod -o -g "$PGID" node` and `usermod -o -u "$PUID" node` (`docker-entrypoint.sh:101-104`). `-o` allows non-unique ids; the stated reason is that `$HOME`, group lookups and `setpriv` resolve even for ids with no passwd entry (`docker-entrypoint.sh:99-100`). Uses `= "$CUR_GID"` string compare — both sides are numeric strings, so it works, but it is a string compare not an integer compare.
- **Ownership taken at startup:**
  - `$HOME_DIR` (`/home/node`) — non-recursive, best-effort `|| true` (`docker-entrypoint.sh:107`).
  - `$STATE` (`/home/node/.dsh`) — **recursive** chown, but only when `needs_chown` finds any non-conforming entry (`docker-entrypoint.sh:111-114`). Predecessor comment names the exact original failure: `EACCES … mkdir '/home/node/.dsh/profiles/web'` (`docker-entrypoint.sh:5-6`).
  - `/workspace` — **mount point only, non-recursive; contents untouched unless `DSH_CHOWN_WORKSPACE=1`** (`docker-entrypoint.sh:116-130`). Recursive chown of `/workspace` is explicitly opt-in because "rewriting ownership across someone's project tree is opt-in, never a silent side effect" (`docker-entrypoint.sh:116-118`).
  - `needs_chown()` is `find "$1" \( ! -uid PUID -o ! -gid PGID \) -print -quit` — early-exit one `stat` in the common case (`docker-entrypoint.sh:44-46`).
- **setpriv, two call sites:** entrypoint (`docker-entrypoint.sh:172`) and the bin wrapper (`run-as-runtime-user.sh:19`). Both use `--init-groups`; the wrapper additionally sets `HOME=/home/node`.
- **The bin wrapper** (`run-as-runtime-user.sh`, installed over `dsh pnpm pnpx pn pnx`): resolves each real target at build time with `readlink -f`, checks `-x`, removes the symlink, writes a copy of the wrapper with `__TARGET__` substituted, `chmod 0755`, then deletes the wrapper source (`Dockerfile:44-53`). A root invocation (`id -u` = 0) re-execs as `PUID:PGID` unless `DSH_ALLOW_ROOT=1` (`run-as-runtime-user.sh:18-21`). Rationale: `docker exec` defaults to root and would otherwise leave root-owned files in the state volume (`run-as-runtime-user.sh:6-11`). Only `dsh` and `pnpm`/`pnpx`/`pn`/`pnx` are wrapped — `node`, `npm`, `sh` are not.
- **`--user` behavior:** entrypoint cannot repair ownership as non-root; it checks `[ -w "$STATE" ]`, and if unwritable prints one actionable line (names owner, says drop `--user` or host-side `chown -R`) and `exit 1`; if writable it runs the doctor with `--check` (report only, unprivileged) and `exec dsh "$@"` (`docker-entrypoint.sh:175-188`).
- **Remaining setuid path: none claimed.** `README.md:109` and `Dockerfile:79-81` assert "nothing setuid is left behind"; the wrapper exists precisely so no setuid helper is needed. **UNVERIFIED** in the sense that no `find / -perm -4000` assertion exists in CI — the smoke test only checks `awk '/^Uid:/{print $2}' /proc/1/status` = 1000 (`sync-upstream.yml:209`).

## 3. Persistence contract

All ENV, `Dockerfile:68-75`:

| Var | Value | Note |
|---|---|---|
| `DSH_HOME` | `/home/node/.dsh` | the state volume **must** be mounted here |
| `PNPM_HOME` | `/home/node/.dsh/.pnpm` | inside state |
| `XDG_CACHE_HOME` | `/home/node/.dsh/.cache` | inside state |
| `XDG_STATE_HOME` | `/home/node/.dsh/.state` | inside state |
| `XDG_CONFIG_HOME` | `/home/node/.dsh/.config` | inside state |
| `DSH_WORKSPACE_DOCTOR` | `repair` | see §7 |
| `PUID` / `PGID` | `1000` / `1000` | runtime identity |

- **Volumes that must be mounted:** `/home/node/.dsh` and `/workspace` (`README.md:257-258`, `:228-229`; `WORKDIR /workspace` `Dockerfile:82`). `/opt/deepseek-harness/web.cordis.patch.yml` is baked, not a volume (`README.md:259`).
- **Fresh root-owned appdata dir:** first start — bind mount arrives host-owned, entrypoint is root, `needs_chown "$STATE"` is true, `chown -R PUID:PGID "$STATE"` fixes it, then drops privileges (`docker-entrypoint.sh:106-114`, `:172`). README states this is the whole point of the root-then-drop design (`README.md:102-107`, `README.md:169-173`). Unraid's share default `99:100` is handled by setting `PUID=99 PGID=100` (`Dockerfile:63-65`; `README.md:172-173`).
- **State volume is entirely dsh-owned and taken wholesale** — comment says safe because it holds settings/credentials/sessions/plugins/pnpm store (`docker-entrypoint.sh:109-110`).
- **Plugin state lives in the volume, not the image:** `/home/node/.dsh/profiles/web` (`README.md:370`), `profiles/web/package.json`, `profiles/web/node_modules` (`docker-entrypoint.sh:60`, `inspect-deployment.yml:78-87`).
- **Workspace registry storage file:** `$STATE/storages/workspace.json` (`docker-entrypoint.sh:163`, `dsh-workspace-doctor.mjs:248`), with backups `workspace.json.bak-<timestamp>` (`docker-entrypoint.sh:163`, `dsh-workspace-doctor.mjs:384`).
- **Credential files** live in state (`README.md:404-405`); the inspection workflow deliberately mounts state read-only and redacts key/token/secret-looking values (`inspect-deployment.yml:6-9`, `:40`, `:81`).
- **Caveat that matters for us:** the workspace *directory picker opens in `/home/node`* (`README.md:273`, `:326`, `:216`), which the next image update erases — the root cause the doctor exists to paper over.

## 4. Reverse-proxy surface — the section most relevant to us

### What `web.cordis.patch.yml` sets
Entire file (`web.cordis.patch.yml:1-10`):
```yaml
- id: webserver
  config:
    host: 0.0.0.0
    port: 3080
```
- Passed via the **supported launcher flag** `--patch`, immediately after `web` (`Dockerfile:114-118`). Upstream's CLI refuses `--host 0.0.0.0` ("deliberate friction: the web UI can execute code"), but the webserver plugin schema accepts exactly `'127.0.0.1' | '0.0.0.0'` (`web.cordis.patch.yml:2-4`). No upstream code is patched (`Dockerfile:9-11`).
- `--patch` **must come immediately after `web`**; placed after the web command's own flags it fails `unknown option '--patch'` (`README.md:265-266`).
- `--no-open` baked into CMD so no in-container browser burns the one-time launch token on 0.1.2+ (`Dockerfile:114-116`, `README.md:113-114`).
- **`EXPOSE 3080`** (`Dockerfile:77`).

### trustedHosts
- **Not set anywhere in the image.** Grep of the whole tree (excluding `.git`) for `trusted[-_]host|trustedHost` matches only README prose and one entrypoint comment (`docker-entrypoint.sh:31`). There is **no `DSH_TRUSTED_HOSTS` env and no baked `--trusted-host`** — `README.md:267-268`: "Nothing deployment-specific is baked in. No `--trusted-host`, no keys, no hostnames."
- It is a **repeatable CLI flag** `--trusted-host <name>`; "port-less entries match any port" (`README.md:160-161`).

### What README instructs for remote access
- Quick start passes `--trusted-host $(hostname)` and opens `http://$(hostname):3080` (`README.md:150-156`).
- Unraid: PostArgs must begin `web --patch /opt/deepseek-harness/web.cordis.patch.yml --no-open` then one `--trusted-host` per browsed name (`README.md:182-184`, `:204-206`, `:225`).
- **Behind a Cloudflare Tunnel:** add the public hostname as `--trusted-host` **and have the tunnel rewrite `Host` to that name (and strip `Origin`)** so the fence sees a trusted name (`README.md:243-245`).
- Credentials/Settings pages are **additionally restricted to loopback origins by upstream design**; README's only remedies are an SSH tunnel `ssh -L 3080:127.0.0.1:3080 root@unraid-ip` + `http://127.0.0.1:3080` (`README.md:208`, `:390-391`), or the third-party `@goodandready/dsh-lanmode` plugin which **only works on 0.1.1 and is NOT compatible with 0.1.2+** (`README.md:208`, `:307-308`, `:386-389`).
- Security model: "Reachability is the perimeter… no TLS… keep it on a trusted LAN or behind an authenticated proxy (Cloudflare Access, Authelia). Never port-forward it to the internet." (`README.md:395-402`, Unraid Overview `:202`).
- 0.1.2+ launch-token: URL printed at startup, rotates each restart, exchanged for a ~30-day cookie **bound to the exact origin**; `README.md:357-366`. Do the exchange on the public FQDN, not the LAN IP, or you do it twice.

### Precise failure chain for a public-FQDN proxy (Pangolin)
1. Client hits `https://dsh.example.com`; Pangolin TLS-terminates and forwards to container `:3080`. If it preserves the client `Host`, the container sees `Host: dsh.example.com`.
2. Upstream's `/api` fence (`/api` refuses any `Host` that isn't loopback or in `--trusted-host`) returns **HTTP 403 on `/api`** — stated three times (`README.md:161-163`, `:206`, `:401-403`). The UI shell may load; every API call fails. This is upstream DNS-rebinding/CSRF protection, not a container bug.
3. Fix for the fence: pass `--trusted-host dsh.example.com` **and** make sure the proxy forwards (or rewrites) `Host` to that exact name, and strips `Origin` if the proxy injects one (`README.md:243-245`).
4. **Independent second fence remains:** Settings/credentials pages stay **loopback-only by upstream design** even with a matching trusted host (`README.md:208`, `:386-391`). ⇒ On a public FQDN you cannot edit settings/API keys through the proxy without either an SSH tunnel or the (0.1.1-only, security-fence-disabling) lanmode plugin. **This is the load-bearing blocker for our design.**
5. On 0.1.2+, before any of the above, an unauthenticated request gets `dsh web authentication required`; the bootstrap URL must be opened at the public origin so the 30-day cookie binds to it (`README.md:357-366`). CI's smoke test encodes the acceptable statuses as `[200, 303, 401]` (`sync-upstream.yml:190`, `:240`).
6. Pangolin-specific: nothing in this repo mentions Pangolin, and it does **not** address `X-Forwarded-Proto`/`X-Forwarded-For`, `Origin` rewriting beyond the Cloudflare one-liner, or WebSocket/SSE upgrade pass-through. **UNVERIFIED for our proxy.**

## 5. PID 1 / signals

- **No tini, no dumb-init, no `--init`, no signal trap, no explicit reaper anywhere.** Grep of the tree for `tini|dumb-init|reaper|SIGTERM|SIGINT|trap` found only unrelated words ("history bootstrap… never runs again") in `dsh-workspace-doctor.mjs:15` and `docker-entrypoint.sh:136`.
- The entrypoint ends in `exec setpriv … dsh "$@"` (`docker-entrypoint.sh:172`), so **`dsh` (node) becomes PID 1 directly** → SIGTERM from `docker stop` reaches dsh without a forwarder; no wrapper to swallow it.
- **The gap:** no child-subreaper. dsh spawns agent shell commands and subagent sessions (`dsh-workspace-doctor.mjs:271` counts `origin === "subagent"`). Orphaned grandchildren are reaped by PID 1; with node as PID 1 and no reaper, zombies accumulate and SIGTERM semantics to grandchildren are undefined. **UNVERIFIED how dsh itself handles this** — this is an upstream property, not something mward4 sets, and the CI smoke test never exercises shutdown (`sync-upstream.yml:203-246` only starts/reads/exits).

## 6. HEALTHCHECK

- **Absent.** Grep for `HEALTHCHECK|healthcheck` over the whole tree returns nothing. Dockerfile ends with `ENTRYPOINT` (`Dockerfile:113`) and `CMD` (`Dockerfile:118`); no `HEALTHCHECK` instruction.
- **Consequences:** orchestrators (Docker Compose `depends_on: condition: service_healthy`, Swarm, k8s without a custom probe) get no health signal; `docker ps` always shows `Up`, never `(healthy)`; a wedged dsh is indistinguishable from a working one. Unraid's template has no healthcheck field either (`README.md:186-234`). The only liveness evidence in the repo is CI fetching `http://<nic>:3080/` and accepting `200/303/401` (`sync-upstream.yml:233-245`).

## 7. Workspace doctor (`dsh-workspace-doctor.mjs`)

- **Storage file it reads:** `$STATE/storages/workspace.json`, path built as `join(state, "storages", "workspace.json")` (`dsh-workspace-doctor.mjs:248`; default state `process.env.DSH_HOME ?? "/home/node/.dsh"` `:65`). Missing registry → prints "no workspace registry … nothing to do" and returns 0 (`:251-255`).
- **Schema assertions:**
  - `KNOWN_UNIT = { name: "workspace", version: 2 }` (`:40`).
  - `doc.unit ?? {}`; requires `doc.tables.workspaces` to be a non-null object else `die` (`:256-258`).
  - Membership read as `record.sessionIds` one-owner-per-session; a session listed by two workspaces gets a warning and is **left untouched** (`:262-268`).
  - Records carry `path`, `title`, `sessionIds`, `updatedAt` (`:300-302`, `:375-376`).
  - **Write gate:** if anything changed and the format is not exactly `workspace v2`, it refuses to write: `refusing to write …: unknown registry format <fmt> (expected workspace v2)` (`:382`). This is the most important coupling: a schema bump upstream makes the doctor a no-op-with-error. **UNVERIFIED whether 0.1.7 still uses `workspace v2`.**
  - Session logs: directory `$STATE/sessions/<bucket>/<sessionId>/`; picks the highest-ranked log by regex `/\.v(\d+)\.jsonl(\.zstd)?$/`, plain `.jsonl` ranked `-1`, anything else `-Infinity` (`:122-126`, `:161-164`). Reads only the **first line** (header), zstd-decompressed via `zlib.zstdDecompressSync` when the file ends `.zstd` and that API exists (`:128-144`). Skips sessions > `MAX_SESSION_BYTES = 64 MiB` (`:44`, `:166-169`).
  - Header must be JSON with `typeof header.cwd === "string"`; uses `header.id`, `header.createdAt`, `header.origin` (`:175-192`).
  - Sessions with `origin === "subagent"` are counted but **never re-attached** (`:271`, `:277`).
- **What it repairs:**
  - `--repair-dirs` / `--all`: `mkdir -p` each missing workspace directory, then `chown -R` it to `--owner` because everything under a just-created path is ours (`:341-362`, `:355`).
  - `--reattach` / `--all`: append session ids whose recorded **canonical** cwd (`realpathSync`, fallback `resolve`) equals a workspace's canonical `path`, and update `record.updatedAt` (`:273-285`, `:364-378`).
  - **Write discipline:** timestamped `copyFile` backup, then atomic replacement — same-dir temp `.workspace-doctor-<uuid>.tmp`, mode `0600`, `handle.sync()`, `rename`, directory fsync (best-effort) (`:218-243`, `:381-390`). Explicitly mirrors dsh's own JSON storage backend (`:213-217`).
  - **Never:** touches a session log, deletes a session, invents a project, or moves a chat into a project it did not run in (`:18-20`, `README.md:338`).
  - Exit contract: `check`/`dry-run` → 1 when something is pending else 0; repair → 1 only if a repair failed (`:394-398`).
- **Is it a workaround for real upstream behavior? Yes.** The header comment states the mechanism (`:6-16`): dsh stores an absolute realpath-canonicalized project directory, joins a session to a project **only at session creation**, plus a one-time history bootstrap that "never runs again". A container update erases anything outside `/workspace` and the state volume; the directory vanishes, chats fall to "Ungrouped" permanently, and adding the folder back creates a **fresh empty project** (`README.md:318-329`). The doctor recreates directories and re-accounts sessions — restoring grouping, not files (`README.md:352-355`).
- **Default mode is `repair`** (`Dockerfile:73`, entrypoint `case "${DSH_WORKSPACE_DOCTOR:-repair}"` `docker-entrypoint.sh:147`); `warn|check|report` → `--check`; `off|no|0` → silent (`docker-entrypoint.sh:147-169`). After a root repair it chowns `workspace.json` + backups back to PUID:PGID (`docker-entrypoint.sh:162-163`).
- Doctor runs **before** privilege drop as root on the normal path; unprivileged (`--user`) path runs `--check` only (`docker-entrypoint.sh:159-161`, `:183-187`).
- CI asserts the doctor is wired: `--help` must succeed, `--check` rc ≤ 1, boot log must contain `^dsh-workspace-doctor:`, and must **not** contain `workspace doctor:` (`sync-upstream.yml:210-232`).

## 8. CI / update

**`sync-upstream.yml`** — schedule `cron: '17 */6 * * *'` (every 6 h); `workflow_dispatch` with `rebuild` input (space-separated versions or `all`); `push` on `main` limited to the build-input paths (`:24-42`). Job steps:
1. **Checkout** `main` (`:61-64`).
2. **Install regctl** `v0.11.6` pinned by SHA-256 `8e0e62a497fcdb8048d18aa927a139613176ba0531f412bc541044e28f9856bd`, verified with `sha256sum -c -` (`:68-77`).
3. **Mirror upstream** `master` + all `dsh-v*` tags via bare clone and force push to the Gitea mirror using `secrets.GITHUB_TOKEN` (`:79-90`).
4. **Plan builds** (`:92-167`): `WANT = "<pnpm latest>|<base digest>|<recipe hash>"` (`:100-105`); candidates = upstream tags also on npm, `>= MIN_VERSION=0.1.1-rc.2`, minus `SKIP_VERSIONS=0.1.3-alpha.2` (native `fs-ext`, needs C toolchain the slim image lacks) (`:49-55`, `:135-144`). Per version: build if tag missing, rebuild if `forced`, else rebuild when stored `dev.milesward.*` labels ≠ `WANT` (`:146-156`). `CURRENT` = newest non-alpha candidate = what `:latest` points at (`:157-160`).
5. **Build / smoke / push** (`:169-278`): `docker build` with all `--build-arg`s; run as a fresh **named volume** at `/home/node/.dsh` (models a new root-owned appdata dir, `:205`); assert `dsh --version`, `pnpm --version`, **`/proc/1/status` Uid = 1000** (`:207-209`); doctor presence/boot-log checks (`:210-232`); fetch `http://<non-internal NIC>:3080/` accepting `[200,303,401]` for up to 30×2 s (`:233-245`); then `docker save` → `regctl image import ocidir://…` → **`--layer-compress gzip`** → `regctl image copy … "$REF"` (`:250-261`). Push uses `regctl registry set --blob-chunk 50000000 --blob-max 50000000` because Cloudflare caps a request at 100 MB (`:182-183`). A failed non-current version warns and is recorded; **if `CURRENT` failed, the run exits 1**; a final step fails the run if any version did not ship (`:264-278`, `:353-357`).
6. **`:latest`** — pure manifest copy through the registry API: read digest of `CURRENT`, `PUT` its manifest body at `latest`; success = HTTP 201, never rebuilds (`:280-302`).
7. **Prune untagged manifests** via the Gitea packages API, keeping any `sha256:` manifest referenced by a tagged index (`:304-331`).
8. **Publish releases** by piping `.gitea/scripts/publish-releases.js` into `node` on the base image so the runner needs nothing installed (`:333-349`).
9. **Fail the run if a version did not ship** (`:351-357`).

**`publish-releases.js`** (278 lines, plain Node 22, zero deps, `:10-11`):
- One Gitea release per image version on the mirrored upstream tag `dsh-v<version>` (`:226-232`); skips if the tag is unmirrored.
- Pulls upstream notes from `api.github.com/repos/deepseek-ai/deepseek-harness/releases/tags/dsh-v<ver>`, keeps the **English half** starting at `<h3 id="en-`, demotes headings, strips "Full Changelog"/`---`, truncates at 9000 chars (`:90-108`).
- Footer: digest, pnpm, base digest, `main@<sha>` · CI run #, dated (`:170-205`); previous digests kept in an HTML-comment history block, last 5 (`:38`, `:199-203`, `:242`).
- Gitea trick: the release whose digest equals `:latest` is the **only non-pre-release** so the repo home page/`/releases/latest` shows something (`:216-224`, `:236-237`).
- Idempotent: compares digest + title + prerelease flag + normalized body, patches only on change (`:239-258`).
- Version compare: semver-ish `VERSION_RE` with alpha<beta<rc<release ordering (`:70-86`).

**Supply-chain verification features present:** regctl pinned version+SHA-256 (`:69-77`); non-floating pnpm via `dist-tags.latest` at plan time (`:100`); base digest captured and compared (`:102-105`, `:126-129`); recipe hash forces rebuild of *every* tag when any build input changes (`:104-105`, `:153-155`); smoke test before push (`:191-246`); byte-level forensic comparison workflow (`validate-suspect-image.yml`); provenance labels read back into release footers (`publish-releases.js:145-152`).
**Supply-chain gaps:** no cosign/sigstore signing, no SLSA attestation, no SBOM, no `docker scout`/trivy scan, no reproducible-build check, no checksum of the npm tarball beyond npm's own integrity, GitHub Actions used by mutable major tag (`actions/checkout@v4`, `:62`). The Dockerfile comment asserts "No upstream code is patched" (`Dockerfile:9`) — enforced only by the *manual* forensic workflow, not by CI on our own image.
**Update mechanics that matter to us:** `:latest` moves only when the planner's `CURRENT` changes → automatically to `0.1.7-rc.2` once upstream tags *and* publishes it to npm and passes the smoke test (`:157-160`, `:233-245`). Per-version tags are immutable in *content of dsh* but are rebuilt in place when recipe/pnpm/base changes (`README.md:286-290`, `:279-284`). Auto-update is deliberately left off in Unraid guidance (`README.md:73`, `:180-181`).

## 9. Unraid template (`README.md:186-234`)

Fields, exact:
- `Name` `DeepSeek-Harness` (`:189`); `Repository` `gitea.milesward.dev/mward4/deepseek-harness:latest` (`:190`); `Registry` (`:191`); `Network` `bridge` (`:192`); `Shell` `sh` (`:193`); `Privileged` `false` (`:194`); `Project`/`Support` links (`:195-196`); long `Overview` (`:197-219`); `Category` `AI: Tools:` (`:220`); `WebUI` `http://[IP]:[PORT:3080]` (`:221`); `TemplateURL` empty; `Icon` gitea raw branch main logo (`:222-223`); `ExtraParams` empty (`:224`).
- **`<PostArgs>`** = `web --patch /opt/deepseek-harness/web.cordis.patch.yml --no-open` (`:225`).
- `<Config>` rows (`:226-233`): `WebUI Port` 3080 tcp required; `DeepSeek API Key` → `DEEPSEEK_API_KEY` optional masked; `DSH Home` path `/mnt/user/appdata/deepseek-harness` → `/home/node/.dsh` rw required; `Workspace` path `/mnt/user/appdata/deepseek-harness/workspace` → `/workspace` rw required; `PUID`=1000; `PGID`=1000; `DSH_CHOWN_WORKSPACE`=0; `DSH_WORKSPACE_DOCTOR`=`repair`.
- Existing containers do **not** gain variables a template adds later; the image default (`repair`) covers the gap (`README.md:237-241`).

**The CMD-replacement footgun (two places):**
- `README.md:182-183`: "Post Arguments replace the image command entirely. Always start with `web --patch … --no-open`, then add one `--trusted-host` per name."
- `Dockerfile:116-117`: "Unraid Post Arguments REPLACE this CMD entirely — operators must repeat the patch flag and `--no-open`."
- Mitigation lives in the entrypoint: if `$#` is 0 → `set -- web --patch "$PATCH" --no-open`; if `$1` starts with `-` → prepend `web --patch "$PATCH" --no-open "$@"`; a full command line passes through untouched (`docker-entrypoint.sh:30-40`). So a bare `--trusted-host tower.local` becomes a valid web invocation. **But** an operator who writes `web --no-open` without the patch flag silently loses the `0.0.0.0` bind — the entrypoint does not inject `--patch` into an explicit `web` invocation.

## 10. Asset classification

| Asset | Verdict | One-line reason |
|---|---|---|
| `LICENSE` | **Reuse verbatim** | Standard MIT; if we fork/copy any file we must carry the copyright notice. |
| `web.cordis.patch.yml` | **Reuse verbatim** | 2 config keys, upstream-supported `--patch` escalation of the bind address; nothing loopback-assuming in it. |
| `Dockerfile` (structure, ENV set, ARG/recipe-hash/label scheme, no-`USER` + setpriv design) | **Adapt conceptually** | Pattern is right, but version default is `0.1.5-rc.2`, base is unpinned, multi-arch is claimed but not built, and it lacks a HEALTHCHECK; adapt rather than copy. |
| `run-as-runtime-user.sh` + the bin-rewrite `RUN` loop (`Dockerfile:44-53`) | **Reuse verbatim** (logic) | Small, self-tested at build time, fixes a real `docker exec` root-file bug; only `setpriv` dependency. |
| `docker-entrypoint.sh` ownership PUID/PGID + setpriv block (`:98-130`, `:171-172`) | **Reuse verbatim** (logic) | Solves the fresh-root-owned-appdata `EACCES` problem without a manual chown; scope distinction (`/workspace` non-recursive) is the careful part. |
| `docker-entrypoint.sh` plugin-collision warning (`:48-96`) | **Adapt conceptually** | Useful, but it greps version-specific paths (`dsh-base`/`dsh-web-app` `cordis.patch.yml`) and shipping-id semantics that we must re-verify on 0.1.7. |
| `docker-entrypoint.sh` doctor wiring (`:132-169`) | **Investigate further** | Tied to `workspace v2` registry format; if 0.1.7 changed it the doctor refuses to write (`dsh-workspace-doctor.mjs:382`). |
| `dsh-workspace-doctor.mjs` | **Investigate further** | Real root-cause workaround, but coupled to `storages/workspace.json` `workspace v2`, session `header.cwd/origin`, zstd session logs, and picks `.vN.jsonl` naming — all must be re-verified against 0.1.7 before reuse. |
| `.gitea/workflows/sync-upstream.yml` regctl 50 MB chunked push (`:19-22`, `:182-183`, `:250-261`) | **Reuse verbatim** (technique) | Directly required for 0.1.7-rc.2 if pushing through Cloudflare's 100 MB cap; layer is already >100 MB since 0.1.6-alpha.2. |
| `.gitea/workflows/sync-upstream.yml` smoke test (`:191-246`) | **Adapt conceptually** | The assertions (version, uid 1000, non-loopback HTTP, doctor wired) are the right contract; must add a real public-Host/trusted-host assertion for our proxy use case. |
| `.gitea/workflows/sync-upstream.yml` planner/freshness/labels (`:92-167`) | **Adapt conceptually** | Solid pnpm/base/recipe staleness detection; Gitea-registry-specific (`package_type=container` API, basic-auth) needs rework for our registry. |
| `.gitea/scripts/publish-releases.js` | **Adapt conceptually** | Gitea-release-generation is not our deliverable; the upstream-notes English-half parsing and digest-history footer are worth lifting if we publish releases. |
| `.gitea/workflows/validate-suspect-image.yml` | **Adapt conceptually** | Excellent forensic method (never executes the suspect), but scoped to a Docker-daemon-on-runner workflow we may not have. |
| `.gitea/workflows/inspect-deployment.yml` | **Adapt conceptually** | Read-only redacting inspector is a good operational template; assumes a specific container name/Unraid host path (`/home/node/.dsh` mount lookup). |
| Unraid XML template (`README.md:186-234`) | **Reject** | Unraid/`PostArgs`-specific; our target is a generic container behind Pangolin, and the template hard-codes a CMD replacement we do not want. |
| `assets/deepseek-logo*.png` | **Reject** | DeepSeek trademark; not needed and no re-use right beyond identifying the upstream project (`README.md:480-484`). |
| `README.md` as a document | **Adapt conceptually** | Prose is Unraid/Cloudflare-flavored and states a false multi-arch claim for us; the *structure* (contract table, upgrade/rollback rules, security model) is the reusable part. |
| Whole-repo "no upstream code patched" premise | **Reuse verbatim** | Correct and worth preserving: install the official npm release, escalate the bind only through upstream's `--patch` seam. |

## 10a. Note on "README troubleshooting"

There is **no section titled Troubleshooting**. The troubleshooting content is distributed across: `Chats land in Ungrouped after an update` (`README.md:318-355`), `What changes in 0.1.2+: launch-token auth` (`:357-366`), `Versions and upgrades` step list incl. plugin reconciliation and the one-off `docker run --rm -v …:/home/node/.dsh … dsh plugin … remove` recovery when the container will not stay up (`:294-316`), the `--user`/writable-volume error contract (`:269-271`, `docker-entrypoint.sh:175-188`), and the `unknown option '--patch'` flag-position failure (`:265-266`). The Unraid `Overview` embeds the same guidance (`:200-216`).

## 11. REMAINS UNVERIFIED

1. **DSH 0.1.7-rc.2 behavior change surface.** Nothing in this repo is newer than `0.1.5-rc.2` (`Dockerfile:18`, `README.md:35`). Specifically unverified for 0.1.7: whether `--trusted-host`/`trustedHosts` still exists and its flag/env name; whether `/api` still 403s non-trusted Hosts; whether Settings/credentials remain loopback-only; whether the launch-token/cookie model changed; whether `workspace v2` is still the registry unit; whether session log naming is still `.vN.jsonl[.zstd]`; whether the plugin-collision id list still reads from `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app` `cordis.patch.yml`.
2. **Multi-arch claim.** `README.md:165` asserts `linux/amd64` and `linux/arm64`; CI only builds amd64 (`sync-upstream.yml:194-202`, no buildx/QEMU). Could not confirm an arm64 manifest exists (no registry access).
3. **Pangolin specifics.** No mention of Pangolin anywhere. Unverified: whether it rewrites/strips `Host` and `Origin`, whether it forwards WebSocket/SSE upgrades, whether it sets `X-Forwarded-Proto`, and whether the upstream fence inspects those headers.
4. **Whether the upstream fence can be satisfied at all for Settings on a public FQDN** without the loopback-only restriction being lifted — README presents no fence-preserving remote option (`README.md:208`, `:390-391`), so this may be a hard blocker for our design.
5. **Setuid-free claim.** No `find -perm -4000` assertion exists; only the uid-1000 PID-1 check is enforced (`sync-upstream.yml:209`).
6. **PID-1 child reaping** and SIGTERM handling of grandchildren: no reaper in the image; upstream dsh behavior not inspected.
7. **Exact registry/image availability** of `gitea.milesward.dev/mward4/deepseek-harness` tags, digests, and whether an arm64 index exists — no network/registry access in this audit.
8. **`.dockerignore`** does not exist, so the whole build context (including `assets/` and README) is sent to the daemon; harmless but unverified as intentional.
9. **`DSH_ALLOW_ROOT=1`** bypass (`run-as-runtime-user.sh:18`) and `DSH_CHOWN_WORKSPACE=1` are documented escape hatches; not exercised by CI.
10. **Whether `zlib.zstdDecompressSync` exists in the shipped Node 22** — the doctor silently skips zstd session logs if not (`dsh-workspace-doctor.mjs:132-133`); not asserted anywhere. This matters if 0.1.7 migrates logs to zstd (README alludes to a V3 format at `0.1.5`, `publish-releases.js:118`).

## 12. Top 5 lessons for our 0.1.7-rc.2 Pangolin-targeted image

1. **The namespaced trusted-host flag is a deployment input, not image state — and it must match the proxy's `Host` metadata exactly.** mward4 bakes none of it (`README.md:267-268`) and passes it in PostArgs; we must require the public FQDN (or wildcard) at run time, ensure Pangolin forwards/rewrites `Host` to it, and strip `Origin`. Plan for the fence, do not disable it.
2. **The loopback-only Settings/credentials fence is a separate, upstream-enforced constraint that trusted hosts do not lift.** A public-FQDN deployment cannot edit settings/API keys through the proxy without an SSH tunnel or a security-fence-disabling plugin. This is the single biggest design risk and must be resolved (upstream config? accepted limitation? bootstrap-only usage?) before we commit — verify against 0.1.7, do not trust the 0.1.5 README.
3. **Ownership repair without `USER` is the right pattern for a bind-mounted state volume: start root, recursive-chown only the state volume, touch only the `/workspace` mount point, drop with `setpriv`, and make `/workspace` recursion explicitly opt-in.** Copy this wholesale; also copy the `--user` detection path that prints an actionable error instead of a Node stack trace (`docker-entrypoint.sh:98-130`, `:175-188`) — it makes the container behave well under orchestrators that force a user.
4. **The chunked-push workaround is mandatory, not optional.** Since `0.1.6-alpha.2` dsh's dependency layer exceeds Cloudflare's 100 MB request cap (`sync-upstream.yml:19-22`); 0.1.7-rc.2 is past that. If our registry path goes through a 100 MB-capped proxy, use `regctl`/`--blob-chunk` and gzip the layers, or pushes will 413.
5. **Everything version-coupled must be re-verified, not inherited.** The doctor writes only `workspace v2` and refuses otherwise (`dsh-workspace-doctor.mjs:382`); the plugin-collision grep and the smoke test accept `[200,303,401]` because they were written for 0.1.2–0.1.5. Before reusing either, confirm 0.1.7's flag names, registry schema, session-log naming, and auth statuses — a wrong assumption here fails at container start, not at build.
