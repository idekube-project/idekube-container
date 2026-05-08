#!/usr/bin/env bash
set -euo pipefail

# ARCH=none causes qemu_common.sh to produce the arch-suffix-less base tag
export ARCH=none
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/qemu_common.sh"

BASE_TAG="$IMAGE_REF"

echo "Creating multi-arch manifest: $BASE_TAG"
docker buildx imagetools create \
    -t "$BASE_TAG" \
    "${BASE_TAG}-amd64" \
    "${BASE_TAG}-arm64"
