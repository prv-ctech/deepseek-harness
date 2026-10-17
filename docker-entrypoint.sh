#!/bin/sh
# Container entrypoint: pick the listener address, fix volume ownership, then
# hand off to `dsh`.
#
# Upstream `dsh` writes into $DSH_HOME and treats process.cwd() as the sandbox
# root, so both of those must be owned by the runtime user. That is the entire
# job here; everything else is passed through untouched — except the bind
# address, which upstream cannot solve for a container (see below).
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
STATE="${DSH_HOME:-/home/node/.dsh}"
HOME_DIR=/home/node
WORKSPACE="${DSH_WORKSPACE_DIR:-/workspace}"
# 0.2.1+ binds one concrete interface address; 0.2.0-rc.2 can only bind
# 127.0.0.1 | 0.0.0.0, and a patch layer is the only way to say 0.0.0.0.
PATCH=/opt/deepseek-harness/proxy.patch.yml
PATCH_WILDCARD=/opt/deepseek-harness/proxy-wildcard.patch.yml
PUBLIC_HOST="${DSH_PUBLIC_HOST:-}"
# Space- or comma-separated extra authorities the /api fence accepts, e.g. a
# LAN address used to reach this container without going through the proxy.
EXTRA_TRUSTED="${DSH_TRUSTED_HOSTS:-}"

log() { printf 'dsh-entrypoint: %s\n' "$*" >&2; }

# One stat in the common case; recursive chown only when something is off.
needs_chown() {
  [ -n "$(find "$1" \( ! -uid "$PUID" -o ! -gid "$PGID" \) -print -quit 2>/dev/null)" ]
}

# The -plus image ships Debian's apktool, and apktool cannot decode a single
# resource without its framework file. The Debian wrapper links that framework
# into ~/.local/share/apktool/framework, but apktool 2.7 resolves the directory
# from XDG_DATA_HOME, which this image redirects into the state volume — so the
# wrapper's link lands where nothing looks, apktool creates a 0-byte 1.apk in
# the directory it does read, and `apktool d` fails with "Could not load
# resources.arsc". Verified both ways.
#
# It is linked here rather than in the image because the state volume is mounted
# over that path: a link baked into a layer would be invisible at runtime, and
# would silently differ between a fresh named volume and an upgraded one.
# Guarded on the framework's presence, so it is a no-op on the base and -chrome
# images, which ship no apktool at all.
android_framework() {
  frame=/usr/share/android-framework-res/framework-res.apk
  dir="${XDG_DATA_HOME:-}/apktool/framework"
  [ -e "$frame" ] && [ -n "${XDG_DATA_HOME:-}" ] || return 0
  if mkdir -p "$dir" 2>/dev/null && ln -sfn "$frame" "$dir/1.apk" 2>/dev/null; then
    # The runtime uid has to own the directory, or a later `apktool if` cannot
    # add a framework to it.
    [ "$(id -u)" = "0" ] && chown "$PUID:$PGID" "$dir" 2>/dev/null || true
  else
    log "warning: cannot link the Android framework for apktool into $dir"
  fi
}

# Which listener contract this `dsh` speaks, decided once here because the image
# ships more than one tracked release. 0.2.1 replaced the wildcard bind with one
# concrete interface address and rejects `0.0.0.0` outright, so from then on the
# address is an argument and the patch layer carries no `webserver` row. A
# 0.2.0-rc.2 schema accepts 127.0.0.1 | 0.0.0.0 only, so that line keeps the
# patch layer. $DSH_VERSION is baked into the image; the fallback covers a build
# that renamed it, and an unreadable version takes the wildcard branch, which is
# what every version before 0.2.1 needs anyway.
version="${DSH_VERSION:-}"
[ -n "$version" ] || version=$(dsh --version 2>/dev/null || true)
at_least() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
concrete_bind=0
if [ -n "$version" ] && at_least "$version" 0.2.1; then
  concrete_bind=1
fi

# Build the arguments for a default `dsh web` launch, then append the caller's.
# Order matters twice over:
#   * Unraid replaces CMD, so a bare flag list must still land after `web`.
#   * `--patch` and `--no-open` are parsed by different parsers. `--patch`
#     belongs to the launcher and must precede the first app-owned flag, while
#     `--no-open`, `--host` and `--trusted-host` belong to the app and must
#     follow it. Supplying a flag the caller already passed would put a launcher
#     flag after an app flag, and dsh then rejects it with `unknown option
#     '--patch'` — so the caller's own flags win and ours are only injected when
#     absent.
#
# `--host` is the one flag the image owns rather than yields: the HEALTHCHECK
# probes the same address (bin/dsh-healthcheck, bin/dsh-bind-host), so a second
# opinion in CMD would leave the container healthy while the port a proxy dials
# answers nothing. DSH_BIND_HOST is the override. The flag is appended last
# because the app parser takes the last occurrence.
if [ "$#" -eq 0 ]; then
  set -- web
fi
case "$1" in
  -*) set -- web "$@" ;;
esac

if [ "$1" = "web" ]; then
  shift
  patch_seen=0
  no_open_seen=0
  host_seen=0
  for argument in "$@"; do
    case "$argument" in
      --patch) patch_seen=1 ;;
      --no-open) no_open_seen=1 ;;
      --host|--host=*) host_seen=1 ;;
    esac
  done

  if [ "$patch_seen" = 1 ]; then
    set -- web "$@"
  elif [ "$concrete_bind" = 1 ]; then
    set -- web --patch "$PATCH" "$@"
  else
    set -- web --patch "$PATCH_WILDCARD" "$@"
  fi
  [ "$no_open_seen" = 1 ] || set -- "$@" --no-open
  if [ "$concrete_bind" = 1 ]; then
    bind_host=$(/usr/local/bin/dsh-bind-host)
    log "binding dsh web to $bind_host"
    if [ -z "${DSH_BIND_HOST:-}" ]; then
      case "$bind_host" in
        127.*|::1)
          log "warning: no non-loopback address to bind, so the GUI answers only inside this container; set DSH_BIND_HOST to the address a proxy can reach"
          ;;
      esac
    fi
    if [ "$host_seen" = 1 ]; then
      log "warning: --host is not used on this image; the entrypoint owns the bind address (set DSH_BIND_HOST instead)"
    fi
    set -- "$@" --host "$bind_host"
  elif [ "$host_seen" = 1 ]; then
    log "warning: --host has no effect on $version; the wildcard patch layer owns the listener"
  fi
  if [ -n "$PUBLIC_HOST" ]; then
    set -- "$@" --trusted-host "$PUBLIC_HOST"
  fi
  for authority in $(printf '%s' "$EXTRA_TRUSTED" | tr ',' ' '); do
    [ -n "$authority" ] && set -- "$@" --trusted-host "$authority"
  done
fi

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$STATE" "$WORKSPACE"

  # The `node` account is deliberately left alone. Renaming its ids with
  # usermod/groupmod needs a writable /etc, which a `--read-only` container does
  # not have, and dsh runs fine as a bare numeric uid as long as HOME, SHELL and
  # DSH_HOME are set (verified: `os.userInfo()` is only consulted as
  # `process.env.SHELL || userInfo().shell`). State is the only tree that must
  # be fully owned, and it is chowned recursively only when it is actually off.
  if needs_chown "$STATE"; then
    log "taking ownership of $STATE as $PUID:$PGID"
    # Fatal if it fails: dsh cannot run without a writable state directory.
    chown -R "$PUID:$PGID" "$STATE"
  fi
  # Single level by design: /workspace is a user mount and recursing over a
  # large tree on every start is a surprise nobody wants. A failure here is only
  # a warning: `--read-only` (or a deliberately read-only mount) makes the
  # workspace unwritable on purpose, and that must not stop the GUI from
  # starting.
  if needs_chown "$WORKSPACE"; then
    if chown "$PUID:$PGID" "$WORKSPACE" 2>/dev/null; then
      log "taking ownership of $WORKSPACE as $PUID:$PGID"
    else
      log "warning: cannot take ownership of $WORKSPACE; leaving it as is"
    fi
  fi
  if [ "$(stat -c %u "$HOME_DIR" 2>/dev/null || echo "$PUID")" != "$PUID" ]; then
    chown "$PUID:$PGID" "$HOME_DIR" 2>/dev/null || log "warning: cannot take ownership of $HOME_DIR"
  fi

  # --clear-groups, not --init-groups: the latter refuses a uid that has no
  # passwd entry ("uid 1234 not found"), which is exactly the Unraid PUID=99
  # case.
  android_framework
  exec setpriv --reuid "$PUID" --regid "$PGID" --clear-groups \
    env HOME="$HOME_DIR" SHELL="${SHELL:-/bin/bash}" DSH_HOME="$STATE" \
    dsh "$@"
fi

# Explicit `--user`: nothing to drop, but a state dir we cannot write is worth
# an actionable error instead of a stack trace at first use.
if [ ! -w "$STATE" ]; then
  log "$STATE is not writable by uid $(id -u):$(id -g)"
  log "on the host run: chown -R $(id -u):$(id -g) <the path mounted at $STATE>"
  log "or start the container as root and set PUID/PGID to the owner instead"
  exit 1
fi

android_framework
exec dsh "$@"
