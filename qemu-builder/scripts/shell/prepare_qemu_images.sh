#!/usr/bin/env bash
set -euo pipefail

normalize_arch() {
    case "$1" in
        aarch64|arm64) echo "arm64" ;;
        x86_64|amd64) echo "amd64" ;;
        *)
            echo "Unsupported architecture: $1" >&2
            exit 1
            ;;
    esac
}

if [[ "${PREPARE_ALL_QEMU_IMAGES:-false}" == "true" ]]; then
    ARCHS=("arm64" "amd64")
elif [[ -n "${QEMU_IMAGE_ARCHS:-}" ]]; then
    IFS=',' read -r -a REQUESTED_ARCHS <<< "${QEMU_IMAGE_ARCHS}"
    ARCHS=()
    for REQUESTED_ARCH in "${REQUESTED_ARCHS[@]}"; do
        ARCHS+=("$(normalize_arch "${REQUESTED_ARCH}")")
    done
else
    ARCHS=("$(normalize_arch "${ARCH:-$(uname -m)}")")
fi
DISTRO="noble"
IMAGE_ENDPOINT="cloud-images.ubuntu.com"
FILES_DIR=".cache/qemu_images"
# Use "current" — the stable pointer to the latest daily build.
# Dated snapshots (e.g. 20260108) are periodically pruned from the mirror,
# which would cause CI 404s on fresh runs without a warm cache.
TAG="current"

echo "Creating directories..."
mkdir -p "${FILES_DIR}"

for ARCH in "${ARCHS[@]}"; do
    if [ ! -f "${FILES_DIR}/${DISTRO}-${ARCH}.img" ]; then
        echo "Downloading Base Image for ${ARCH}..."
        wget -O "${FILES_DIR}/${DISTRO}-${ARCH}.img" "https://${IMAGE_ENDPOINT}/${DISTRO}/${TAG}/${DISTRO}-server-cloudimg-${ARCH}.img"
    else
        echo "Base Image for ${ARCH} Present"
    fi
done

# VDISK_SIZE=10G
# if [ ! -f "assets/${DISTRO}-${ARCH}.qcow2" ]; then
#     echo "Creating the diff image"
#     pushd assets
#     qemu-img create -f qcow2 -o backing_file=${DISTRO}-${ARCH}.img,backing_fmt=qcow2 ${DISTRO}-${ARCH}.qcow2 ${VDISK_SIZE}
#     popd
# fi
