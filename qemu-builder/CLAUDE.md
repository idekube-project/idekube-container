# CLAUDE.md

## Project Purpose

idekube-container-qemu-builder is a build and provisioning system that produces QEMU-based VM disk images from Ubuntu cloud images, packages them as multi-arch Docker containers, and optionally converts them to WSL2-importable rootfs tarballs. It is part of the IDEKube platform for containerized development environments.

## Tech Stack

- **Build orchestration**: Bash scripts
- **Virtualization**: QEMU 10.2.0 (compiled from source)
- **Guest OS**: Ubuntu 24.04 LTS (Noble)
- **Provisioning**: cloud-init + Ansible
- **Packaging**: Docker / Buildx (multi-arch manifests)
- **Architectures**: amd64 (x86_64) and arm64 (aarch64)
- **UEFI firmware**: EDK2 (aarch64), OVMF (x86_64)
- **WSL2 conversion**: libguestfs / guestfish

## Project Structure

```
scripts/shell/
  qemu_common.sh          - Shared variables (registry, tag, arch normalization, build args)
  prepare_qemu_files.sh   - Downloads QEMU tarball, extracts UEFI firmware .fd files
  prepare_qemu_images.sh  - Downloads Ubuntu cloud images for both architectures
  prepare_qemu_tools.sh   - Builds guest payloads: idekube-healthcheck binaries, landing page (frontend-dist)
  build_qemu_root.sh      - Boots VM via QEMU, provisions with cloud-init + Ansible, outputs root.img
  build_qemu.sh           - Builds the final runtime Docker image (Dockerfile)
  build_wsl.sh            - Converts provisioned qcow2 to WSL2 rootfs tarball
  manifest_qemu.sh        - Creates multi-arch Docker manifest (amd64 + arm64)
  publish_qemu.sh         - Pushes images to container registry
  test_qemu.sh            - Smoke test of a runtime image (make qemu-test BRANCH=...); needs KVM

artifacts/configs/
  user-data.yaml           - cloud-init user-data template (build-time; patched at runtime)
  meta-data.yaml           - cloud-init meta-data (empty)

artifacts/rootfs/           - VM-only files: etc/idekube/vm-init.sh (UID remap, SSH keys,
                              shell, startup hooks)
artifacts/featured/rootfs/  - VM-only desktop overrides: Chromium flags (panel launcher,
                              keyboard shortcuts), TurboVNC xstartup/launcher
artifacts/startup-scripts/
  startup.sh               - Container entrypoint; validates IDEKUBE_*, seeds the disk, patches cloud-init config, then exec run.sh
  run.sh                   - QEMU launcher and supervisor: arch/accel, disk resize, loopback port relay,
                             clean guest power-off on SIGTERM
  idekube-env.sh           - IDEKUBE_* parsing (booleans, integers, Docker addresses); identical copy of
                             ../artifacts/rootfs/usr/local/lib/idekube/env.sh

manifests/qemu/
  Dockerfile               - Runtime container: engine base + provisioned root.img
  Dockerfile.engine         - QEMU engine base: compiles QEMU, bundles firmware + cloud-init utils

tools/utility/
  cloud-localds/Dockerfile  - Utility image for cloud-localds
  qemu-to-wsl/              - Converter: qcow2 -> WSL2 rootfs tarball (guestfish + virt-tar-out)
```

## Three-Stage Image Construction

1. **QEMU Engine Base** (`Dockerfile.engine`): Compiles QEMU 10.2.0 from source with KVM/VNC/slirp support. Bundles UEFI firmware files, cloud-init configs, and startup scripts. Base image: `ubuntu:24.04`.

2. **Provisioned Disk** (`build_qemu_root.sh`): Copies a cloud image, boots it in QEMU, applies cloud-init (creates `idekube` user with sudo, password `idekube` for Ansible), rsyncs the rootfs layers into the VM (`sync_rootfs` in `qemu_common.sh`: the meta-repo's `artifacts/rootfs` and `images/<flavor>-base/.../rootfs`, the same files the containers use, minus the supervisor/container init, then the VM-only files above; `/etc/skel/.bashrc` gets its VM additions from `install.yml`), runs an Ansible playbook (`manifests/qemu/<branch>/install.yml`) with the flavor's base-target build args from `../docker-bake.hcl` as variables (playbooks pin no versions), copies the landing page from `prepare_qemu_tools.sh`, then cleanly shuts down. Output: `root.img` (qcow2).

3. **Runtime Container** (`Dockerfile`): Layers the provisioned `root.img` on top of the engine base. Entrypoint: `/startup.sh`.

## Runtime Initialization Flow

```
Container start
  -> startup.sh: validates every IDEKUBE_* value (exit with a message on a bad
     one), copies UEFI/configs to working dir, seeds root.img only if absent
     (or IDEKUBE_VM_RESET_DISK=true), writes a fresh cloud-init instance-id,
     patches user-data.yaml (disables ssh_pwauth, drops chpasswd, locks the
     password, injects write_files for runtime-env, adds runcmd for vm-init.sh)
  -> exec run.sh (stays the container's main process): detects arch, picks the
     accelerator (KVM when /dev/kvm opens read-write, else TCG unless
     IDEKUBE_VM_REQUIRE_KVM), resizes disk, generates cloud-init ISO, starts the
     socat relays and QEMU, then supervises them; SIGTERM -> QMP
     system_powerdown -> wait IDEKUBE_VM_SHUTDOWN_TIMEOUT -> stop QEMU
  -> QEMU boots guest
  -> cloud-init: writes /etc/idekube/runtime-env
  -> idekube-authn.service: authn.sh renders the nginx token config
     (before nginx.service, which Requires= it)
  -> featured/kathara: idekube-docker-network.service writes Docker's bip and
     default-address-pools (before docker.service)
  -> cloud-init runcmd -> vm-init.sh: UID remap, preferred shell, home init
     from /etc/skel, SSH authorized keys (base64-decoded), locks the password,
     disables SSH password auth, runs /etc/idekube/startup.bash/*.sh hooks
```

## Key Concepts

- **cloud-init**: Used both at build time (user creation, password auth for Ansible) and at runtime (injecting env vars, triggering vm-init.sh). The build-time `user-data.yaml` is patched at runtime by `startup.sh`.
- **UEFI firmware**: EDK2 for aarch64, OVMF for x86_64. Extracted from the QEMU source tarball during `prepare_qemu_files.sh`.
- **Accelerator detection**: `run.sh` uses HVF (macOS) or KVM (Linux, when `/dev/kvm` opens read-write), else TCG software emulation. `IDEKUBE_VM_DISABLE_KVM` forces TCG; `IDEKUBE_VM_REQUIRE_KVM` makes missing KVM a startup error.
- **Configuration parsing**: booleans are `true/false`, `1/0`, `yes/no`, `on/off`; empty means unset; anything else stops the container in `startup.sh` (`idekube-env.sh`). `IDEKUBE_VM_RESET_DISK=false` keeps the disk.
- **Loopback relay**: libslirp gives the guest a forwarded connection's real source address unless it is loopback. In the container, socat relays the published ports to slirp forwards on `127.0.0.1:61022/61080`, so the guest always sees `10.0.2.2` (a guest network covering the real source, e.g. kathara's docker0 vs. Docker's `172.17.0.1`, made the guest drop forwarded SYNs as martians).
- **Shutdown**: `run.sh` runs QEMU in the background (stdin kept for the serial console) and turns SIGTERM/SIGINT/SIGHUP into an ACPI power-off over the private QMP socket `./qemu-qmp.sock`, waiting up to `IDEKUBE_VM_SHUTDOWN_TIMEOUT` (25 s) before `quit`/kill. The container's stop grace period must be longer.
- **Nginx token auth**: `authn.sh` renders `/etc/nginx/conf.d/access_token.conf` from the read-only template `/etc/idekube/nginx/access_token.conf.template` on every boot (token map), writes a permit-all map when no token is set, and a deny-all map plus non-zero exit on any failure. The image ships the deny-all map.
- **WSL2 conversion**: `build_wsl.sh` uses libguestfs to apply WSL-specific tweaks (wsl.conf, blank fstab, disable cloud-init) and exports the rootfs as a tarball importable via `wsl --import`.
- **IDEKUBE_FROM**: Allows layering builds; copies `root.img` from a previously built branch instead of a fresh cloud image.

## Configuration

### Build-Time Environment Variables

| Variable | Default | Description |
|---|---|---|
| `BRANCH` | (required) | Build flavor/branch path (e.g., `featured/base`) |
| `REGISTRY` | `docker.io` | Container registry |
| `AUTHOR` | `davidliyutong` | Registry namespace |
| `NAME` | `idekube-container` | Image name prefix (appended with `-qemu`) |
| `GIT_TAG` | latest git tag | Image version tag |
| `TAG_POSTFIX` | `""` | Suffix appended to the image tag |
| `ARCH` | host arch | Target architecture (`amd64` or `arm64`) |
| `DISTRO` | `noble` | Ubuntu codename for cloud image |
| `IDEKUBE_FROM` | (unset) | Source branch for layered builds |
| `IDEKUBE_VM_MEMORY` | `4G` | VM memory during provisioning |
| `IDEKUBE_VM_CPU` | `2` | VM CPUs during provisioning |
| `IDEKUBE_VM_DISK_SIZE` | `10G` | VM disk size during provisioning |

### Runtime Environment Variables

| Variable | Default | Description |
|---|---|---|
| `IDEKUBE_VM_MEMORY` | `1G` | VM memory allocation |
| `IDEKUBE_VM_CPU` | `1` | VM CPU count |
| `IDEKUBE_VM_DISK_SIZE` | (unset) | Resize disk on boot (only grows) |
| `IDEKUBE_VM_HEADLESS` | `true` | Headless mode (no graphical output) |
| `IDEKUBE_VM_DISABLE_KVM` | `false` | Force software emulation |
| `IDEKUBE_VM_REQUIRE_KVM` | `false` | Exit instead of falling back to software emulation |
| `IDEKUBE_VM_SHUTDOWN_TIMEOUT` | `25` | Seconds the guest gets to power off after SIGTERM |
| `IDEKUBE_USER_UID` | (unset) | Remap idekube user UID |
| `IDEKUBE_AUTHORIZED_KEYS` | (unset) | Base64-encoded SSH authorized_keys |
| `IDEKUBE_PREFERED_SHELL` | `/bin/bash` | Default shell for idekube user |
| `IDEKUBE_INIT_HOME` | `false` | Re-initialize home from /etc/skel |
| `IDEKUBE_ACCESS_TOKEN` | (unset) | Nginx access token, `[A-Za-z0-9._-]+` (unset = permit all; invalid = nginx stays down) |
| `IDEKUBE_VM_RESET_DISK` | `false` | `true` replaces an existing `root.img` in the work dir (default: keep it) |
| `IDEKUBE_VM_DOCKER_BIP` | `10.213.0.1/24` | featured/kathara: the VM's docker0 address |
| `IDEKUBE_VM_DOCKER_ADDRESS_POOLS` | `10.214.0.0/16:24` | featured/kathara: Docker default-address-pools (`base/len:size[,...]`) |
| `IDEKUBE_SSH_PORT` | `22` | Host port for SSH forwarding |
| `IDEKUBE_WEB_PORT` | `80` | Host port for HTTP forwarding |
| `IDEKUBE_MONITOR_SOCKET` | `./qemu-monitor.sock` | QEMU monitor unix socket |
| `IDEKUBE_MONITOR_PORT` | (unset) | Opt-in telnet monitor on 127.0.0.1 only |
| `IDEKUBE_VM_HOSTFWD_ADDR` | (empty = relay) | Empty: loopback relay on all interfaces; set: slirp listens there directly (native build mode) |

## Networking

QEMU user-mode networking with port forwards (through the loopback relay in the container):
- SSH: container port -> socat -> 127.0.0.1:61022 -> guest :22
- HTTP: container port -> socat -> 127.0.0.1:61080 -> guest :80
- VNC is not forwarded (passwordless; guest-local, reached via nginx `/vnc`)
- QEMU monitor: unix socket in the work dir, never a network port

The featured flavor nginx reverse-proxies internal services: noVNC (:6081), code-server (:3000), WebSocket SSH (:2222), and a health endpoint (:9999).
