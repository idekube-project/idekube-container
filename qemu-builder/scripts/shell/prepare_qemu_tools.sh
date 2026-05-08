#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
META_ROOT="$(cd "${QEMU_ROOT}/.." && pwd)"
OUT_DIR="${QEMU_ROOT}/.cache/qemu_tools"

mkdir -p "${OUT_DIR}"

for arch in amd64 arm64; do
    echo "Building idekube-healthcheck for linux/${arch}..."
    if command -v go >/dev/null 2>&1; then
        (
            cd "${META_ROOT}/healthcheck"
            GOOS=linux GOARCH="${arch}" CGO_ENABLED=0 go build -o "${OUT_DIR}/idekube-healthcheck.${arch}" .
        )
    else
        docker run --rm \
            --user "$(id -u):$(id -g)" \
            -e HOME=/tmp \
            -e GOCACHE=/tmp/go-build \
            -e GOMODCACHE=/tmp/go-mod \
            -v "${META_ROOT}/healthcheck:/src" \
            -v "${OUT_DIR}:/out" \
            -w /src \
            golang:1.25-alpine \
            sh -c "GOOS=linux GOARCH=${arch} CGO_ENABLED=0 go build -o /out/idekube-healthcheck.${arch} ."
    fi
done

echo "QEMU guest tools are ready in ${OUT_DIR}."
