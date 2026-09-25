#!/bin/sh
# Print the recipe hash baked into a published image, or exit non-zero when the
# tag does not exist. Used by .github/workflows/build.yml to decide whether an
# RC needs (re)building, so a Dockerfile fix reaches versions that were already
# published instead of only the next RC.
#
# Reads the image config over the OCI registry API instead of `docker buildx
# imagetools`: the labels live in the config blob, so this needs nothing beyond
# curl and jq, and it can be exercised against any local registry.
#
# usage: published-recipe.sh <registry> <repository> <tag> [bearer-token]
# env:   REGISTRY_SCHEME  http for a plain-HTTP registry (default https)
set -eu

registry="$1"
repository="$2"
tag="$3"
token="${4:-}"
scheme="${REGISTRY_SCHEME:-https}"

# Both media-type families are offered: a registry storing OCI manifests
# answers 404 when only the Docker type is requested.
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'

# Anonymous pull works for public packages; private ones need a token, which a
# caller that already holds one passes in.
if [ -z "$token" ] && [ "$scheme" = "https" ]; then
  token=$(curl -fsSL "https://${registry}/token?scope=repository:${repository}:pull" 2>/dev/null \
    | jq -r '.token // empty' || true)
fi

if [ -n "$token" ]; then
  set -- -H "Authorization: Bearer ${token}"
else
  set --
fi

# A tag may resolve to a multi-arch index; take the linux/amd64 manifest.
manifest=$(curl -fsSL "$@" -H "Accept: $accept" \
  "${scheme}://${registry}/v2/${repository}/manifests/${tag}") || exit 1

digest=$(printf '%s' "$manifest" | jq -r '
  if .manifests then
    (.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest)
  else .config.digest end')
case "$digest" in sha256:*) ;; *) exit 1 ;; esac

curl -fsSL "$@" -H 'Accept: application/vnd.oci.image.config.v1+json' \
  "${scheme}://${registry}/v2/${repository}/blobs/${digest}" \
  | jq -r '.config.Labels["org.opencontainers.image.dsh-recipe"] // empty'
