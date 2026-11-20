#!/bin/bash
#
# startup.sh — QEMU container entrypoint.
# Prepares the working directory, generates a dynamic cloud-init
# user-data.yaml from IDEKUBE_* environment variables, then launches
# the QEMU VM via run.sh.
#

set -e

WORK_DIR="/var/lib/data"
SOURCE_DIR="/var/lib/idekube"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=idekube-env.sh
source "${SCRIPT_DIR}/idekube-env.sh"

# Validate the configuration before anything touches the disk. Values usually
# come from Kubernetes manifests or templates: empty means "not set", and a
# value that does not parse stops the container with a message instead of
# being guessed at (a stray "false" must never reset a student's disk).
RESET_DISK=$(idekube_bool IDEKUBE_VM_RESET_DISK) || exit 1
INIT_HOME=$(idekube_bool IDEKUBE_INIT_HOME) || exit 1
DOCKER_BIP=$(idekube_docker_bip IDEKUBE_VM_DOCKER_BIP "") || exit 1
DOCKER_POOLS=$(idekube_docker_pools IDEKUBE_VM_DOCKER_ADDRESS_POOLS "") || exit 1
# Parsed again by run.sh; checked here so that a bad value fails fast.
idekube_bool IDEKUBE_VM_HEADLESS 1 >/dev/null || exit 1
DISABLE_KVM=$(idekube_bool IDEKUBE_VM_DISABLE_KVM) || exit 1
REQUIRE_KVM=$(idekube_bool IDEKUBE_VM_REQUIRE_KVM) || exit 1
if [ "${DISABLE_KVM}" = 1 ] && [ "${REQUIRE_KVM}" = 1 ]; then
    echo "Error: IDEKUBE_VM_DISABLE_KVM and IDEKUBE_VM_REQUIRE_KVM are both true" >&2
    exit 1
fi
idekube_uint IDEKUBE_VM_SHUTDOWN_TIMEOUT 25 >/dev/null || exit 1

echo "Preparing QEMU environment in ${WORK_DIR}..."

cd "${WORK_DIR}"

# Copy UEFI firmware files
echo "Copying UEFI firmware files..."
mkdir -p ./uefi
cp -r "${SOURCE_DIR}/uefi/"*.fd ./uefi/

# Copy configuration files (meta-data.yaml, etc.)
echo "Copying configuration files..."
mkdir -p ./configs
cp -r "${SOURCE_DIR}/configs/"* ./configs/

# Seed the root disk image. ${WORK_DIR} may be a persistent volume: an
# existing root.img holds the user's system and files, so it is only replaced
# when IDEKUBE_VM_RESET_DISK is true. The copy goes through a temp file so an
# interrupted first copy never leaves a truncated root.img behind.
mkdir -p ./images
if [ -f ./images/root.img ] && [ "${RESET_DISK}" != 1 ]; then
    echo "Keeping existing root disk image ./images/root.img (set IDEKUBE_VM_RESET_DISK=true to reset it)."
else
    [ -f ./images/root.img ] && echo "IDEKUBE_VM_RESET_DISK is true: replacing ./images/root.img with the image's disk."
    echo "Copying root disk image..."
    if ! cp "${SOURCE_DIR}/images/root.img" ./images/root.img.tmp; then
        rm -f ./images/root.img.tmp
        echo "Error: Failed to copy root disk image from ${SOURCE_DIR}/images/root.img" >&2
        echo "       The image may not have been built. Run 'make qemu-root BRANCH=<flavor>/<variant>' first." >&2
        exit 1
    fi
    mv -f ./images/root.img.tmp ./images/root.img
fi

# Give every container start a new cloud-init instance-id. With a persisted
# disk, cloud-init would otherwise treat the boot as already provisioned and
# skip write_files/runcmd, so a changed IDEKUBE_* environment (for example a
# rotated access token) would never reach the VM. Side effect: SSH host keys
# are regenerated on each start, as for a freshly created container.
printf 'instance-id: idekube-%s\n' "$(cat /proc/sys/kernel/random/uuid)" > ./configs/meta-data.yaml

# ------------------------------------------------------------------
# Patch the build-time user-data.yaml (copied above from ${SOURCE_DIR}/configs)
# for runtime: flip ssh_pwauth off and append a write_files entry for
# /etc/idekube/runtime-env plus a runcmd invoking vm-init.sh.
# ------------------------------------------------------------------
echo "Patching cloud-init user-data.yaml for runtime..."

USER_DATA="./configs/user-data.yaml"

# Generate runtime-env content.
# Values are single-quoted for safe shell-sourcing from vm-init.sh: this
# preserves multi-line values (e.g. unwrapped-base64 IDEKUBE_AUTHORIZED_KEYS
# produced by `base64` without -w 0) and values containing spaces or shell
# metacharacters (e.g. IDEKUBE_ACCESS_TOKEN).
# NOTE: IDEKUBE_ACCESS_TOKEN is included so that authn.sh (called by
# vm-init.sh at VM boot) can replace __IDEKUBE_ACCESS_TOKEN_PLACEHOLDER__
# in the baked-in /etc/nginx/conf.d/access_token.conf template.
write_runtime_var() {
    local name="$1" value="$2"
    # Escape embedded single quotes: ' -> '\''
    local escaped=${value//\'/\'\\\'\'}
    printf "%s='%s'\n" "$name" "$escaped"
}

generate_runtime_env() {
    echo "# IDEKube runtime environment"
    [ -n "${IDEKUBE_USER_UID:-}" ]        && write_runtime_var IDEKUBE_USER_UID        "$IDEKUBE_USER_UID"
    [ -n "${IDEKUBE_AUTHORIZED_KEYS:-}" ] && write_runtime_var IDEKUBE_AUTHORIZED_KEYS "$IDEKUBE_AUTHORIZED_KEYS"
    [ -n "${IDEKUBE_PREFERED_SHELL:-}" ]  && write_runtime_var IDEKUBE_PREFERED_SHELL  "$IDEKUBE_PREFERED_SHELL"
    [ "${INIT_HOME}" = 1 ]                && write_runtime_var IDEKUBE_INIT_HOME       true
    [ -n "${DOCKER_BIP}" ]                && write_runtime_var IDEKUBE_VM_DOCKER_BIP   "$DOCKER_BIP"
    [ -n "${DOCKER_POOLS}" ]              && write_runtime_var IDEKUBE_VM_DOCKER_ADDRESS_POOLS "$DOCKER_POOLS"
    [ -n "${IDEKUBE_ACCESS_TOKEN:-}" ]    && write_runtime_var IDEKUBE_ACCESS_TOKEN    "$IDEKUBE_ACCESS_TOKEN"
    return 0
}

# The build-time config gives idekube the password "idekube" for Ansible.
# At runtime: no password SSH, no chpasswd (it would set the password again
# on every boot), and the password locked (key SSH and sudo keep working).
sed -i 's/^ssh_pwauth:.*/ssh_pwauth: false/' "$USER_DATA"
sed -i 's/^\([[:space:]]*\)lock_passwd:.*/\1lock_passwd: true/' "$USER_DATA"
awk '/^[^[:space:]#]/ { skip = ($0 ~ /^chpasswd:/) } !skip' "$USER_DATA" > "$USER_DATA.tmp"
mv -f "$USER_DATA.tmp" "$USER_DATA"

# Append runtime-only sections. The build-time file has no write_files or
# runcmd keys, so appending as new top-level keys is safe.
{
    echo ""
    echo "write_files:"
    echo "  - path: /etc/idekube/runtime-env"
    echo "    content: |"
    generate_runtime_env | sed 's/^/      /'
    echo "    owner: root:root"
    echo "    permissions: '0600'"
    echo ""
    echo "runcmd:"
    echo "  - [bash, /etc/idekube/vm-init.sh]"
} >> "$USER_DATA"

echo "Environment preparation complete."
echo "Starting QEMU..."

exec /run.sh
