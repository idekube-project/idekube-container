#!/usr/bin/env bash
# tag-stable.sh — retag a pushed image with a "stable" alias.
#
# Usage:
#   ./scripts/tag-stable.sh <branch> [version] [lineup]
#
# Where:
#   branch  is in slash-form, e.g. featured/base, agent/openclaw, jupyter/speit-ascendai
#   version defaults to the current git tag (`git describe --tags --abbrev=0`).
#   lineup  is universal, ascend, or all; defaults to $LINEUP or universal.
#
# The script maps a branch to (registry repo, variant tag) using the same
# convention as docker-bake.hcl:
#
#   featured/base                -> idekube-container-featured-base : <version>
#   featured/speit               -> idekube-container-featured      : speit-<version>
#   featured/speit-ai            (also takes -ascend variant)
#   coder/base, coder/conda
#   jupyter/base, jupyter/speit-ai, jupyter/speit-ascendai
#   agent/base, agent/openclaw, agent/hermes
#
# It then runs `docker buildx imagetools create` to create a new tag aliasing
# the existing manifest. Base-image repos use stable / stable-ascend; app repos
# use <variant>-stable / <variant>-stable-ascend.

set -euo pipefail

BRANCH="${1:-}"
VERSION="${2:-${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo latest)}}"
LINEUP="${3:-${LINEUP:-universal}}"
REGISTRY="${REGISTRY:-ghcr.io}"
AUTHOR="${AUTHOR:-idekube-project}"
NAME_PREFIX="${NAME_PREFIX:-idekube-container}"

if [[ -z "$BRANCH" ]]; then
    echo "Usage: $0 <flavor>/<variant> [version] [lineup]" >&2
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

supports_ascend() {
    case "$BRANCH" in
        featured/base|featured/speit-ai|jupyter/base|jupyter/speit-ai|jupyter/speit-ascendai)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

release_tag() {
    local postfix="$1"
    if [[ "$variant" == "base" ]]; then
        echo "${VERSION}${postfix}"
    else
        echo "${variant}-${VERSION}${postfix}"
    fi
}

stable_tag() {
    local postfix="$1"
    if [[ "$variant" == "base" ]]; then
        echo "stable${postfix}"
    else
        echo "${variant}-stable${postfix}"
    fi
}

retag() {
    local postfix="$1"
    local src="${REGISTRY}/${AUTHOR}/${repo}:$(release_tag "$postfix")"
    local dst="${REGISTRY}/${AUTHOR}/${repo}:$(stable_tag "$postfix")"
    echo "Retagging $src -> $dst"
    docker buildx imagetools create -t "$dst" "$src"
}

case "$LINEUP" in
    universal)
        retag ""
        ;;
    ascend)
        if supports_ascend; then
            retag "-ascend"
        else
            echo "Skipping $BRANCH: no ascend lineup tag"
        fi
        ;;
    all)
        retag ""
        if supports_ascend; then
            retag "-ascend"
        fi
        ;;
    *)
        echo "Error: unknown lineup $LINEUP (expected universal, ascend, or all)" >&2
        exit 1
        ;;
esac
