#!/bin/sh
# Container entrypoint: fix volume ownership, then hand off to `dsh`.
#
# Upstream `dsh` writes into $DSH_HOME and treats process.cwd() as the sandbox
# root, so both of those must be owned by the runtime user. That is the entire
# job here; everything else is passed through untouched.
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
STATE="${DSH_HOME:-/home/node/.dsh}"
HOME_DIR=/home/node
WORKSPACE="${DSH_WORKSPACE_DIR:-/workspace}"
PATCH=/opt/deepseek-harness/proxy.patch.yml
PUBLIC_HOST="${DSH_PUBLIC_HOST:-}"
# Space- or comma-separated extra authorities the /api fence accepts, e.g. a
# LAN address used to reach this container without going through the proxy.
EXTRA_TRUSTED="${DSH_TRUSTED_HOSTS:-}"

log() { printf 'dsh-entrypoint: %s\n' "$*" >&2; }

# One stat in the common case; recursive chown only when something is off.
needs_chown() {
  [ -n "$(find "$1" \( ! -uid "$PUID" -o ! -gid "$PGID" \) -print -quit 2>/dev/null)" ]
}

# Build the arguments for a default `dsh web` launch, then append the caller's.
# Order matters: Unraid replaces CMD, so a bare flag list must still land after
# the `web` subcommand.
if [ "$#" -eq 0 ]; then
  set -- web
fi
case "$1" in
  -*) set -- web "$@" ;;
esac

if [ "$1" = "web" ]; then
  shift
  set -- web --patch "$PATCH" --no-open "$@"
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

exec dsh "$@"
