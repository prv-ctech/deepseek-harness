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
# usage: published-recipe.sh <registry> <repository> <tag> [github-token]
# env:   REGISTRY_SCHEME  http for a plain-HTTP registry (default https)
#
# The optional credential is a GitHub token (GITHUB_TOKEN or a PAT), used to
# exchange for a registry token when the package is private. Omit it for public
# packages. A registry bearer token is not accepted here — pass none, or the
# token endpoint's Basic auth would reject it.
set -eu

registry="$1"
repository="$2"
tag="$3"
credential="${4:-}"
scheme="${REGISTRY_SCHEME:-https}"

# Both media-type families are offered: a registry storing OCI manifests
# answers 404 when only the Docker type is requested.
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'

# A GitHub token (GITHUB_TOKEN or a PAT) is NOT itself a registry bearer token:
# presenting one raw makes ghcr answer 403. It has to be exchanged at the token
# endpoint, which wants it as the Basic-auth password. With no credential at
# all, the same endpoint still hands out an anonymous token, which is all a
# public package needs.
if [ "$scheme" = "https" ]; then
  if [ -n "${credential:-}" ]; then
    token=$(curl -fsSL -u "x-access-token:${credential}" \
      "https://${registry}/token?scope=repository:${repository}:pull" 2>/dev/null \
      | jq -r '.token // empty' || true)
  else
    token=$(curl -fsSL "https://${registry}/token?scope=repository:${repository}:pull" 2>/dev/null \
      | jq -r '.token // empty' || true)
  fi
fi

if [ -n "${token:-}" ]; then
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
