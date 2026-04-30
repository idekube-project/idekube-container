#!/usr/bin/env bash
# tag-stable.sh — retag a pushed image with a "stable" alias.
#
# Usage:
#   ./scripts/tag-stable.sh <branch> [version]
#
# Where:
#   branch  is in slash-form, e.g. featured/base, agent/openclaw, jupyter/speit-ascendai
#   version defaults to the current git tag (`git describe --tags --abbrev=0`).
#
# The script maps a branch to (registry repo, variant tag) using the same
# convention as docker-bake.hcl:
#
#   featured/base                -> idekube-container-featured-base : base-<version>
#   featured/speit               -> idekube-container-featured      : speit-<version>
#   featured/speit-ai            (also takes -ascend variant)
#   coder/base, coder/conda
#   jupyter/base, jupyter/speit-ai, jupyter/speit-ascendai
#   agent/base, agent/openclaw, agent/hermes
#
# It then runs `docker buildx imagetools create` to create a new tag aliasing
# the existing manifest. Both the lineup-postfix variants (e.g. base-ascend)
# and the plain variant get aliased to <variant>-stable / <variant>-stable-ascend.

set -euo pipefail

BRANCH="${1:-}"
VERSION="${2:-${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo latest)}}"
REGISTRY="${REGISTRY:-ghcr.io}"
AUTHOR="${AUTHOR:-idekube-project}"
NAME_PREFIX="${NAME_PREFIX:-idekube-container}"

if [[ -z "$BRANCH" ]]; then
    echo "Usage: $0 <flavor>/<variant> [version]" >&2
    exit 1
fi

flavor="${BRANCH%%/*}"
variant="${BRANCH#*/}"

# Determine which submodule (and therefore which GHCR repo) owns this branch.
case "$BRANCH" in
    featured/base) repo="${NAME_PREFIX}-featured-base" ;;
    featured/*)    repo="${NAME_PREFIX}-featured" ;;
    coder/base)    repo="${NAME_PREFIX}-coder-base" ;;
    coder/*)       repo="${NAME_PREFIX}-coder" ;;
    jupyter/base)  repo="${NAME_PREFIX}-jupyter-base" ;;
    jupyter/*)     repo="${NAME_PREFIX}-jupyter" ;;
    agent/base)    repo="${NAME_PREFIX}-agent-base" ;;
    agent/*)       repo="${NAME_PREFIX}-agent" ;;
    *)
        echo "Error: unknown branch $BRANCH" >&2
        exit 1
        ;;
esac

retag() {
    local postfix="$1"
    local src="${REGISTRY}/${AUTHOR}/${repo}:${variant}-${VERSION}${postfix}"
    local dst="${REGISTRY}/${AUTHOR}/${repo}:${variant}-stable${postfix}"
    echo "Retagging $src -> $dst"
    docker buildx imagetools create -t "$dst" "$src"
}

# Always retag the base-lineup variant.
retag ""

# Some branches also have an ascend variant; retag if present.
case "$BRANCH" in
    featured/base|featured/speit-ai|jupyter/base|jupyter/speit-ai|jupyter/speit-ascendai)
        retag "-ascend" || echo "warning: ascend variant for $BRANCH not found, skipping"
        ;;
esac
