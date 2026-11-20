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

# Landing page. The containers build it in their frontend-builder stage
# (images/*/docker/base/Dockerfile); this mirrors that stage: same node image,
# VITE_APP_VERSION=<version>-<frontend tree hash>. The version is resolved
# like qemu_common.sh's GIT_TAG (VERSION, GIT_TAG, else the newest git tag).
GIT_TAG=${VERSION:-${GIT_TAG:-latest}}
if [[ "${GIT_TAG}" == "latest" ]]; then
    GIT_TAG=$(git -C "${META_ROOT}" tag --list --sort=-v:refname | head -n 1 || true)
    GIT_TAG=${GIT_TAG:-latest}
fi
FRONTEND_VERSION="${GIT_TAG}-$(bash "${META_ROOT}/scripts/ci/frontend-hash.sh")"
FRONTEND_OUT="${OUT_DIR}/frontend-dist"
echo "Building the landing page (${FRONTEND_VERSION})..."
rm -rf "${FRONTEND_OUT}"
mkdir -p "${FRONTEND_OUT}"
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e VITE_APP_VERSION="${FRONTEND_VERSION}" \
    -v "${META_ROOT}/frontend:/src:ro" \
    -v "${FRONTEND_OUT}:/out" \
    node:22-alpine \
    sh -ec 'mkdir /tmp/build
            tar -C /src --exclude=./node_modules --exclude=./dist -cf - . | tar -C /tmp/build -xf -
            cd /tmp/build
            npm ci --no-audit --no-fund
            npm run build
            cp -a dist/. /out/'
printf '%s\n' "${FRONTEND_VERSION}" > "${FRONTEND_OUT}/.idekube-version"

echo "QEMU guest tools are ready in ${OUT_DIR}."
