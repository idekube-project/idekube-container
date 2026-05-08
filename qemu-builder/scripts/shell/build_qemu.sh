#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/qemu_common.sh"
# ARCH, BRANCH, IMAGE_REF, DOCKER_BUILD_ARGS

# build the image
echo "Building $IMAGE_REF with $BRANCH branch"
echo "Build Args: $DOCKER_BUILD_ARGS"

if [[ ! -f "${ROOT_DISK_IMAGE_PATH}" ]]; then
  echo "Error: provisioned root disk not found: ${ROOT_DISK_IMAGE_PATH}" >&2
  echo "       Run 'BRANCH=${BRANCH} bash scripts/shell/build_qemu_root.sh' first." >&2
  exit 1
fi

ROOT_DISK_CONTEXT="$(dirname "${ROOT_DISK_IMAGE_PATH}")"
docker build $DOCKER_BUILD_ARGS -t $IMAGE_REF-$ARCH -t $IMAGE_REF -f manifests/qemu/Dockerfile "${ROOT_DISK_CONTEXT}"
