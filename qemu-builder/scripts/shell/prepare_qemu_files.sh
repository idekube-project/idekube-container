#!/usr/bin/env bash
set -euo pipefail

QEMU_VERSION="10.2.0"
QEMU_URL="https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"
FILES_DIR=".cache/qemu_files"

mkdir -p "${FILES_DIR}"

# Download QEMU if not already present
if [ -f "${FILES_DIR}/qemu-${QEMU_VERSION}.tar.xz" ]; then
    echo "QEMU tarball already downloaded, skipping download..."
else
    echo "Downloading QEMU ${QEMU_VERSION}..."
    curl -L -o "${FILES_DIR}/qemu-${QEMU_VERSION}.tar.xz" "${QEMU_URL}"
fi

# Extract if not already extracted
if [ -d "${FILES_DIR}/qemu-${QEMU_VERSION}" ]; then
    echo "QEMU already extracted, skipping extraction..."
else
    echo "Extracting tarball..."
    tar -xf "${FILES_DIR}/qemu-${QEMU_VERSION}.tar.xz" -C "${FILES_DIR}"
fi

echo "Extracting aarch64 UEFI firmware..."
bunzip2 -c "${FILES_DIR}/qemu-${QEMU_VERSION}/pc-bios/edk2-aarch64-code.fd.bz2" > "${FILES_DIR}/edk2-aarch64-code.fd"
bunzip2 -c "${FILES_DIR}/qemu-${QEMU_VERSION}/pc-bios/edk2-arm-vars.fd.bz2" > "${FILES_DIR}/edk2-arm-vars.fd"

echo "Extracting x86_64 UEFI firmware..."
bunzip2 -c "${FILES_DIR}/qemu-${QEMU_VERSION}/pc-bios/edk2-x86_64-code.fd.bz2" > "${FILES_DIR}/OVMF_CODE.fd"
bunzip2 -c "${FILES_DIR}/qemu-${QEMU_VERSION}/pc-bios/edk2-i386-vars.fd.bz2" > "${FILES_DIR}/OVMF_VARS.fd"

echo "Done! UEFI firmware files are in ${FILES_DIR}/"
