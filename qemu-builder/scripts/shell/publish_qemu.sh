#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/qemu_common.sh"

# Ensure BRANCH, REGISTRY, AUTHOR, NAME, TAG, IMAGE_REF, and ARCH are set
if [ -z "$ARCH" ]; then
    echo "docker push $IMAGE_REF"
    docker push "$IMAGE_REF"
else
    echo "docker push $IMAGE_REF-$ARCH"
    docker push "$IMAGE_REF-$ARCH"
fi
