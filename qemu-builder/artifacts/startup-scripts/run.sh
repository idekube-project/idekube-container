#!/bin/bash
#
# run.sh — launch and supervise the IDEKube QEMU VM.
#
# Runs as the QEMU container's main process (startup.sh execs it) and in
# build_qemu_root.sh's native mode. It stays in the foreground:
#   - SSH (guest :22) and the nginx gateway (guest :80) are forwarded into the
#     guest. Inside a container (IDEKUBE_VM_HOSTFWD_ADDR empty) they go
#     through a loopback relay, see "Port forwarding" below.
#   - SIGTERM/SIGINT/SIGHUP (docker stop, Pod deletion) power the guest off
#     through ACPI and wait up to IDEKUBE_VM_SHUTDOWN_TIMEOUT seconds before
#     QEMU is stopped, so the guest flushes its disks like a normal shutdown.
#   - The container exits when QEMU does (including a poweroff inside the
#     guest), or with an error if a port relay dies.
#
# Boolean variables take true/false, 1/0, yes/no, on/off; empty means unset;
# anything else is a configuration error (see idekube-env.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=idekube-env.sh
source "${SCRIPT_DIR}/idekube-env.sh"

VM_MEMORY="${IDEKUBE_VM_MEMORY:-1G}"
VM_CPU="${IDEKUBE_VM_CPU:-1}"
VM_DISK_SIZE="${IDEKUBE_VM_DISK_SIZE:-}"
EXPOSE_SSH_PORT=$(idekube_uint IDEKUBE_SSH_PORT 22) || exit 1
EXPOSE_WEB_PORT=$(idekube_uint IDEKUBE_WEB_PORT 80) || exit 1
# Address the SSH/HTTP forwards listen on. Empty = all interfaces through the
# loopback relay (the runtime container); build_qemu_root.sh's native mode
# sets 127.0.0.1.
HOSTFWD_ADDR="${IDEKUBE_VM_HOSTFWD_ADDR:-}"

HEADLESS=$(idekube_bool IDEKUBE_VM_HEADLESS 1) || exit 1
DISABLE_KVM=$(idekube_bool IDEKUBE_VM_DISABLE_KVM) || exit 1
REQUIRE_KVM=$(idekube_bool IDEKUBE_VM_REQUIRE_KVM) || exit 1
SHUTDOWN_TIMEOUT=$(idekube_uint IDEKUBE_VM_SHUTDOWN_TIMEOUT 25) || exit 1

for port in "${EXPOSE_SSH_PORT}" "${EXPOSE_WEB_PORT}"; do
    if (( port < 1 || port > 65535 )); then
        echo "Error: port ${port} (IDEKUBE_SSH_PORT/IDEKUBE_WEB_PORT) is out of range" >&2
        exit 1
    fi
done

# QEMU monitor. It needs no credentials and can pause the VM or read guest
# memory, so it is never exposed on the network: by default it is a unix
# socket in the working directory (reach it with e.g.
# `socat - UNIX-CONNECT:./qemu-monitor.sock`). Setting IDEKUBE_MONITOR_PORT
# opts into a telnet monitor bound to 127.0.0.1 only.
if [[ -n "${IDEKUBE_MONITOR_PORT:-}" ]]; then
    MONITOR_OPTS="telnet:127.0.0.1:${IDEKUBE_MONITOR_PORT},server,nowait"
    MONITOR_DESC="telnet 127.0.0.1:${IDEKUBE_MONITOR_PORT}"
else
    MONITOR_SOCKET="${IDEKUBE_MONITOR_SOCKET:-./qemu-monitor.sock}"
    MONITOR_OPTS="unix:${MONITOR_SOCKET},server,nowait"
    MONITOR_DESC="unix socket ${MONITOR_SOCKET}"
fi
# QMP socket used only by this script, to power the guest off on SIGTERM.
QMP_SOCKET="./qemu-qmp.sock"

# ---------------------------------------------------------------------------
# Accelerator
# ---------------------------------------------------------------------------
# KVM is used when /dev/kvm can actually be opened read-write, which also
# catches a device node that exists without permission to use it.
# IDEKUBE_VM_REQUIRE_KVM=true turns "no KVM" into a startup error instead of
# a slow software-emulated VM.
if [[ "${DISABLE_KVM}" == "1" && "${REQUIRE_KVM}" == "1" ]]; then
    echo "Error: IDEKUBE_VM_DISABLE_KVM and IDEKUBE_VM_REQUIRE_KVM are both true" >&2
    exit 1
fi

kvm_unusable_reason() {
    if [[ ! -e /dev/kvm ]]; then
        echo "/dev/kvm does not exist (no KVM on this host, or the container was started without --device /dev/kvm)"
    elif ! ( exec 3<>/dev/kvm ) 2>/dev/null; then
        echo "/dev/kvm exists but uid $(id -u) cannot open it read-write"
    fi
}

ARCH=$(uname -m)
if [[ "$(uname)" == "Darwin" ]]; then
    ACCELERATOR=" -accel hvf "
    CPU_TYPE="host"
elif [[ "$(uname)" == "Linux" ]]; then
    KVM_REASON=""
    if [[ "${DISABLE_KVM}" == "1" ]]; then
        KVM_REASON="IDEKUBE_VM_DISABLE_KVM is true"
    else
        KVM_REASON=$(kvm_unusable_reason)
    fi
    if [[ -z "${KVM_REASON}" ]]; then
        ACCELERATOR=" -accel kvm "
        CPU_TYPE="host"
    else
        if [[ "${REQUIRE_KVM}" == "1" ]]; then
            echo "Error: IDEKUBE_VM_REQUIRE_KVM is true but KVM is not usable: ${KVM_REASON}" >&2
            exit 1
        fi
        ACCELERATOR=""
        echo "Warning: KVM acceleration disabled (${KVM_REASON}); using software emulation" >&2
        if [[ "${ARCH}" == "arm64" || "${ARCH}" == "aarch64" ]]; then
            CPU_TYPE="cortex-a72"
        elif [[ "${ARCH}" == "x86_64" ]]; then
            CPU_TYPE="qemu64,+aes,+ssse3,+sse4.1,+sse4.2,+avx,+avx2,+bmi2,+smep,+bmi1,+fma,+movbe"
        else
            echo "Unsupported architecture for CPU type detection" >&2
            exit 1
        fi
    fi
else
    echo "Unsupported OS for acceleration" >&2
    exit 1
fi
echo "Using CPU type: ${CPU_TYPE}, Acceleration: ${ACCELERATOR}"

# Graphics options
if [[ "${HEADLESS}" == "1" ]]; then
    GRAPHICS_OPTS="-nographic"
else
    GRAPHICS_OPTS="-device virtio-gpu-pci -display default,show-cursor=on -device qemu-xhci -device usb-kbd -device usb-tablet -device intel-hda -device hda-duplex"
fi

# Set QEMU binary and firmware based on architecture
if [[ "${ARCH}" == "arm64" || "${ARCH}" == "aarch64" ]]; then
    QEMU_BIN="qemu-system-aarch64"
    MACHINE_TYPE="virt"
    if [[ -f "./uefi/edk2-aarch64-code.fd" && -f "./uefi/edk2-arm-vars.fd" ]]; then
        FIRMWARE_OPTS="-drive if=pflash,format=raw,readonly=on,file=./uefi/edk2-aarch64-code.fd -drive if=pflash,format=raw,file=./uefi/edk2-arm-vars.fd"
    else
        FIRMWARE_OPTS=""
        echo "Warning: aarch64 UEFI firmware not found, booting without UEFI" >&2
    fi
elif [[ "${ARCH}" == "x86_64" ]]; then
    QEMU_BIN="qemu-system-x86_64"
    MACHINE_TYPE="q35"
    # Check if OVMF firmware files exist, use them if available
    if [[ -f "./uefi/OVMF_CODE.fd" && -f "./uefi/OVMF_VARS.fd" ]]; then
        FIRMWARE_OPTS="-drive if=pflash,format=raw,readonly=on,file=./uefi/OVMF_CODE.fd -drive if=pflash,format=raw,file=./uefi/OVMF_VARS.fd"
    else
        FIRMWARE_OPTS=""
        echo "Warning: OVMF firmware not found, booting without UEFI" >&2
    fi
else
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Port forwarding
# ---------------------------------------------------------------------------
# libslirp hands a forwarded connection to the guest with its real source
# address, unless that address is loopback (then the guest sees 10.0.2.2).
# A source such as Docker's bridge gateway 172.17.0.1, or an ingress Pod IP,
# collides with any guest network covering it: with Docker running in the
# guest (featured/kathara), docker0 = 172.17.0.1/16 makes the guest drop
# every forwarded SYN as a martian. So inside a container the forwards
# listen on loopback only and socat relays the published ports to them: the
# guest always sees 10.0.2.2, whatever the cluster's address plan.
SLIRP_SSH_PORT=61022
SLIRP_WEB_PORT=61080
if [[ -z "${HOSTFWD_ADDR}" ]]; then
    RELAY=1
    SLIRP_ADDR=127.0.0.1
    if [[ " ${EXPOSE_SSH_PORT} ${EXPOSE_WEB_PORT} " == *" ${SLIRP_SSH_PORT} "* || " ${EXPOSE_SSH_PORT} ${EXPOSE_WEB_PORT} " == *" ${SLIRP_WEB_PORT} "* ]]; then
        echo "Error: ports ${SLIRP_SSH_PORT} and ${SLIRP_WEB_PORT} are reserved for the internal relay; choose other IDEKUBE_SSH_PORT/IDEKUBE_WEB_PORT values" >&2
        exit 1
    fi
    if ! command -v socat >/dev/null 2>&1; then
        echo "Error: socat is required to relay ports into the VM" >&2
        exit 1
    fi
else
    RELAY=0
    SLIRP_ADDR="${HOSTFWD_ADDR}"
    SLIRP_SSH_PORT="${EXPOSE_SSH_PORT}"
    SLIRP_WEB_PORT="${EXPOSE_WEB_PORT}"
fi

NETWORK_OPTS=""
if ${QEMU_BIN} -machine ${MACHINE_TYPE} -netdev help 2>&1 | grep -q "user"; then
    # Only SSH (key auth) and the nginx gateway (token auth) are forwarded.
    # VNC stays inside the guest: it has no password and noVNC reaches it
    # through the gateway's /vnc route.
    NETWORK_OPTS="-netdev user,id=net0,hostfwd=tcp:${SLIRP_ADDR}:${SLIRP_SSH_PORT}-:22,hostfwd=tcp:${SLIRP_ADDR}:${SLIRP_WEB_PORT}-:80 -device virtio-net-pci,netdev=net0,disable-modern=off,disable-legacy=on"
else
    echo "Warning: 'user' network backend not available, networking will be disabled" >&2
    NETWORK_OPTS=""
fi

# If cloud-localds exists, init the cloud-init drive
if command -v cloud-localds >/dev/null 2>&1; then
    echo "cloud-localds found, generating cloud-init.iso..."
    cloud-localds ./configs/cloud-init.iso ./configs/user-data.yaml ./configs/meta-data.yaml
else
    echo "cloud-localds not found, skipping cloud-init.iso generation."
fi

# Validate and resize root disk image
DISK_IMAGE="./images/root.img"

if [[ ! -f "${DISK_IMAGE}" ]]; then
    echo "Error: Disk image ${DISK_IMAGE} not found" >&2
    exit 1
fi

echo "Validating disk image..."
if ! qemu-img info "${DISK_IMAGE}" >/dev/null 2>&1; then
    echo "Error: Invalid disk image ${DISK_IMAGE}" >&2
    exit 1
fi

# Resize disk if VM_DISK_SIZE is specified
if [[ -n "${VM_DISK_SIZE}" ]]; then
    echo "Checking disk size..."
    CURRENT_SIZE=$(qemu-img info --output=json "${DISK_IMAGE}" | jq -r '."virtual-size"')

    # Parse target size to bytes (support G/M/K suffixes)
    TARGET_SIZE_STR="${VM_DISK_SIZE}"
    if [[ "${TARGET_SIZE_STR}" =~ ^([0-9]+)([GMK])?$ ]]; then
        TARGET_NUM="${BASH_REMATCH[1]}"
        TARGET_UNIT="${BASH_REMATCH[2]}"
        case "${TARGET_UNIT}" in
            G) TARGET_SIZE=$(echo "${TARGET_NUM} * 1024 * 1024 * 1024" | bc) ;;
            M) TARGET_SIZE=$(echo "${TARGET_NUM} * 1024 * 1024" | bc) ;;
            K) TARGET_SIZE=$(echo "${TARGET_NUM} * 1024" | bc) ;;
            *) TARGET_SIZE=${TARGET_NUM} ;;
        esac

        SHOULD_RESIZE=$(echo "${TARGET_SIZE} > ${CURRENT_SIZE}" | bc 2>/dev/null || echo "0")
        if [[ "${SHOULD_RESIZE}" == "1" ]]; then
            CURRENT_SIZE_GB=$(echo "scale=2; ${CURRENT_SIZE} / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "unknown")
            echo "Resizing disk from ${CURRENT_SIZE_GB}G to ${VM_DISK_SIZE}..."
            if ! qemu-img resize "${DISK_IMAGE}" "${VM_DISK_SIZE}"; then
                echo "Warning: Failed to resize disk image" >&2
            fi
        else
            echo "Disk size ${VM_DISK_SIZE} is not larger than current size (${CURRENT_SIZE}), skipping resize."
        fi
    else
        echo "Warning: Invalid disk size format: ${VM_DISK_SIZE}" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Start and supervise
# ---------------------------------------------------------------------------
RELAY_PIDS=()
QEMU_PID=""
SHUTTING_DOWN=0
RELAY_FAILED=0

qmp() {
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" \
        | socat -t 5 - "UNIX-CONNECT:${QMP_SOCKET}" >/dev/null 2>&1
}

shutdown_vm() {
    (( SHUTTING_DOWN )) && return
    SHUTTING_DOWN=1
    if [[ -z "${QEMU_PID}" ]]; then
        # Signalled before QEMU was started: nothing to power off.
        for pid in "${RELAY_PIDS[@]}"; do kill "${pid}" 2>/dev/null; done
        exit 0
    fi
    kill -0 "${QEMU_PID}" 2>/dev/null || return
    echo "Stopping: asking the guest to power off (up to ${SHUTDOWN_TIMEOUT}s)..." >&2
    if ! qmp system_powerdown; then
        echo "Warning: could not reach QMP at ${QMP_SOCKET} to power the guest off" >&2
    fi
    local waited=0
    while kill -0 "${QEMU_PID}" 2>/dev/null && (( waited < SHUTDOWN_TIMEOUT )); do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "${QEMU_PID}" 2>/dev/null; then
        echo "Guest did not power off within ${SHUTDOWN_TIMEOUT}s; stopping QEMU." >&2
        qmp quit || true
        sleep 2
        kill -TERM "${QEMU_PID}" 2>/dev/null || true
    else
        echo "Guest powered off." >&2
    fi
}
trap shutdown_vm TERM INT HUP

if (( RELAY )); then
    socat "TCP-LISTEN:${EXPOSE_SSH_PORT},fork,reuseaddr" "TCP:127.0.0.1:${SLIRP_SSH_PORT}" &
    RELAY_PIDS+=($!)
    socat "TCP-LISTEN:${EXPOSE_WEB_PORT},fork,reuseaddr" "TCP:127.0.0.1:${SLIRP_WEB_PORT}" &
    RELAY_PIDS+=($!)
    echo "Relaying :${EXPOSE_SSH_PORT} and :${EXPOSE_WEB_PORT} to the VM through loopback"
fi

echo "Starting QEMU with monitor on ${MONITOR_DESC}..."

# Not exec'd: this script must outlive QEMU's start to turn SIGTERM into an
# ACPI power-off. <&0 keeps the serial console on the container's stdin
# (a background job would otherwise get /dev/null).
# shellcheck disable=SC2086  # option strings are split on purpose
${QEMU_BIN} \
    -M ${MACHINE_TYPE} \
    ${FIRMWARE_OPTS} \
    -cpu ${CPU_TYPE} \
    ${ACCELERATOR} \
    -m ${VM_MEMORY} \
    -smp ${VM_CPU},sockets=1,cores=${VM_CPU},threads=1 \
    ${GRAPHICS_OPTS} \
    -monitor "${MONITOR_OPTS}" \
    -qmp "unix:${QMP_SOCKET},server=on,wait=off" \
    -serial mon:stdio \
    -drive file=./images/root.img,format=qcow2,if=virtio,cache=writethrough,index=0,media=disk \
    -drive file=./configs/cloud-init.iso,index=1,media=cdrom \
    -boot order=c \
    ${NETWORK_OPTS} <&0 &
QEMU_PID=$!

# Poll instead of a bare `wait`: a trapped signal interrupts `wait` on the
# short sleep immediately, and a dead relay is noticed within a second.
while kill -0 "${QEMU_PID}" 2>/dev/null; do
    for pid in "${RELAY_PIDS[@]}"; do
        if (( ! SHUTTING_DOWN )) && ! kill -0 "${pid}" 2>/dev/null; then
            echo "Error: port relay (pid ${pid}) exited; shutting the VM down" >&2
            RELAY_FAILED=1
            shutdown_vm
        fi
    done
    sleep 1 &
    wait $! 2>/dev/null
done
wait "${QEMU_PID}"
QEMU_STATUS=$?

for pid in "${RELAY_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
done

if (( RELAY_FAILED )); then
    exit 1
elif (( SHUTTING_DOWN )); then
    exit 0
fi
exit "${QEMU_STATUS}"
