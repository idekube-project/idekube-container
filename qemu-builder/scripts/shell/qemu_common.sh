#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
META_ROOT="$(cd "${QEMU_ROOT}/.." && pwd)"

# QEMU scripts use paths relative to qemu-builder. Normalize the working
# directory so they can be launched from either the meta-repo root or
# qemu-builder itself.
cd "${QEMU_ROOT}"

# Assemble a flavor's VM rootfs overlay at <dest> with <transport...> (an
# rsync-compatible command: vm_rsync in build_qemu_root.sh, plain rsync in
# tests). Layers, later ones win:
#   1. ../artifacts/rootfs: what every image shares (authn.sh, nginx maps and
#      snippets, skel), minus the container-only init (supervisor, startup.sh)
#   2. ../images/<flavor>-base/artifacts/docker/<flavor>/rootfs: the flavor's
#      container overlay (nginx site, desktop config), minus supervisor
#   3. artifacts/rootfs and artifacts/<flavor>/rootfs here: VM-only files
# The container images and the VM thus read the same nginx/auth/desktop
# files; qemu-builder only keeps what the VM does differently.
function sync_rootfs {
  local flavor=$1 dest=$2
  shift 2
  local container_only=(--exclude=/etc/supervisor/ --exclude=/startup.sh --exclude=/init-containers.sh)
  local layers=(
    "${META_ROOT}/artifacts/rootfs"
    "${META_ROOT}/images/${flavor}-base/artifacts/docker/${flavor}/rootfs"
    "${QEMU_ROOT}/artifacts/rootfs"
    "${QEMU_ROOT}/artifacts/${flavor}/rootfs"
  )
  local layer
  for layer in "${layers[@]}"; do
    [[ -d "$layer" ]] || continue
    echo "Copying rootfs layer ${layer#"${META_ROOT}/"}..."
    "$@" "${container_only[@]}" "${layer}/" "${dest}"
  done
}

function build_docker_args {
  local env_file=$1
  if [[ ! -f "$env_file" ]]; then
    return
  fi

  local build_args=""
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ -z "$key" ]] && continue

    build_args+=" --build-arg ${key}=${value}"
  done < "$env_file"

  echo "$build_args"
}

if [[ -z "${BRANCH:-}" ]]; then
  echo "BRANCH is not set"
  exit 1
fi

# set default values
REGISTRY=${REGISTRY:-"ghcr.io"}
AUTHOR=${AUTHOR:-"idekube-project"}
NAME_PREFIX=${NAME_PREFIX:-${NAME:-"idekube-container"}}

FLAVOR="${BRANCH%%/*}"
VARIANT="${BRANCH#*/}"
if [[ "$FLAVOR" == "$BRANCH" || -z "$VARIANT" ]]; then
  echo "BRANCH must use <flavor>/<variant> form, got: $BRANCH" >&2
  exit 1
fi

case "$BRANCH" in
  featured/base) NAME="${NAME_PREFIX}-featured-base" ;;
  featured/*)    NAME="${NAME_PREFIX}-featured" ;;
  coder/base)    NAME="${NAME_PREFIX}-coder-base" ;;
  coder/*)       NAME="${NAME_PREFIX}-coder" ;;
  jupyter/base)  NAME="${NAME_PREFIX}-jupyter-base" ;;
  jupyter/*)     NAME="${NAME_PREFIX}-jupyter" ;;
  agent/base)    NAME="${NAME_PREFIX}-agent-base" ;;
  agent/*)       NAME="${NAME_PREFIX}-agent" ;;
  *)
    echo "Unsupported QEMU branch: $BRANCH" >&2
    exit 1
    ;;
esac

# Match docker-bake.hcl and tests/helpers/images.py: VERSION is the repo-wide
# release variable, with GIT_TAG retained as a legacy fallback.
GIT_TAG=${VERSION:-${GIT_TAG:-latest}}
if [[ "$GIT_TAG" == "latest" ]]; then
  LATEST_TAG=$(git -C "${META_ROOT}" tag --list --sort=-v:refname | head -n 1 || true)
  GIT_TAG=${LATEST_TAG:-latest}
fi
TAG_POSTFIX=${TAG_POSTFIX:-""}
QEMU_POSTFIX=${QEMU_POSTFIX:-"-qemu"}
DOCKER_BRANCH=$(echo "$BRANCH" | sed 's/\//-/g')
if [[ "$VARIANT" == "base" ]]; then
  TAG="${GIT_TAG}${TAG_POSTFIX}${QEMU_POSTFIX}"
else
  TAG="${VARIANT}-${GIT_TAG}${TAG_POSTFIX}${QEMU_POSTFIX}"
fi

IMAGE_REF=$REGISTRY/$AUTHOR/$NAME:$TAG

ROOT_DISK_IMAGE_DIR=${ROOT_DISK_IMAGE_DIR:-".cache"}
ROOT_DISK_IMAGE_PATH="${ROOT_DISK_IMAGE_DIR}/${BRANCH}/images/root.img"

# build docker build args
DOCKER_BUILD_ARGS=$(build_docker_args ".dockerargs")
DOCKER_BUILD_ARGS+=" --build-arg REGISTRY=$REGISTRY"
DOCKER_BUILD_ARGS+=" --build-arg AUTHOR=$AUTHOR"
DOCKER_BUILD_ARGS+=" --build-arg NAME=$NAME"
DOCKER_BUILD_ARGS+=" --build-arg GIT_TAG=$GIT_TAG"

# set ARCH variable
ARCH=${ARCH:-$(uname -m)}
# if ARCH equals to aarch64, then set the ARCH to arm64, if ARCH equals to x86_64, then set the ARCH to amd64
if [ "$ARCH" == "aarch64" ]; then
  ARCH="arm64"
elif [ "$ARCH" == "x86_64" ]; then
  ARCH="amd64"
elif [ "$ARCH" == "none" ]; then
  ARCH=""
fi
