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
  build_qemu_root.sh      - Boots VM via QEMU, provisions with cloud-init + Ansible, outputs root.img
  build_qemu.sh           - Builds the final runtime Docker image (Dockerfile)
  build_wsl.sh            - Converts provisioned qcow2 to WSL2 rootfs tarball
  manifest_qemu.sh        - Creates multi-arch Docker manifest (amd64 + arm64)
  publish_qemu.sh         - Pushes images to container registry

artifacts/configs/
  user-data.yaml           - cloud-init user-data template (build-time; patched at runtime)
  meta-data.yaml           - cloud-init meta-data (empty)

artifacts/rootfs/
  authn.sh                 - Nginx access-token authentication setup
  etc/idekube/vm-init.sh   - Runtime VM initialization (UID remap, SSH keys, shell, startup hooks)
  etc/idekube/startup.bash/ - Directory for custom startup hook scripts (.sh)
  etc/nginx/conf.d/access_token.conf - Nginx token auth map template

artifacts/featured/rootfs/  - Feature flavor overlays (XFCE desktop, TurboVNC, noVNC, code-server)
artifacts/startup-scripts/
  startup.sh               - Container entrypoint; patches cloud-init config, then exec run.sh
  run.sh                   - QEMU launcher; detects arch/accel, resizes disk, starts VM

manifests/qemu/
  Dockerfile               - Runtime container: engine base + provisioned root.img
  Dockerfile.engine         - QEMU engine base: compiles QEMU, bundles firmware + cloud-init utils

tools/utility/
  cloud-localds/Dockerfile  - Utility image for cloud-localds
  qemu-to-wsl/              - Converter: qcow2 -> WSL2 rootfs tarball (guestfish + virt-tar-out)
```

## Three-Stage Image Construction

1. **QEMU Engine Base** (`Dockerfile.engine`): Compiles QEMU 10.2.0 from source with KVM/VNC/slirp support. Bundles UEFI firmware files, cloud-init configs, and startup scripts. Base image: `ubuntu:24.04`.

2. **Provisioned Disk** (`build_qemu_root.sh`): Copies a cloud image, boots it in QEMU, applies cloud-init (creates `idekube` user with sudo), rsyncs rootfs overlays into the VM, runs an Ansible playbook (`manifests/qemu/<branch>/install.yml`), copies frontend dist, then cleanly shuts down. Output: `root.img` (qcow2).

3. **Runtime Container** (`Dockerfile`): Layers the provisioned `root.img` on top of the engine base. Entrypoint: `/startup.sh`.

## Runtime Initialization Flow

```
Container start
  -> startup.sh: copies UEFI/configs/disk to working dir, patches user-data.yaml
     (disables ssh_pwauth, injects write_files for runtime-env, adds runcmd for vm-init.sh)
  -> exec run.sh: detects arch, configures accelerator (KVM/HVF/TCG), resizes disk,
     generates cloud-init ISO, launches QEMU
  -> QEMU boots guest
  -> cloud-init: writes /etc/idekube/runtime-env, runs vm-init.sh
  -> vm-init.sh: UID remap, preferred shell, home init from /etc/skel,
     SSH authorized keys (base64-decoded), authn.sh (nginx token auth),
     disables SSH password auth, runs /etc/idekube/startup.bash/*.sh hooks,
     restarts nginx
```

## Key Concepts

- **cloud-init**: Used both at build time (user creation, password auth for Ansible) and at runtime (injecting env vars, triggering vm-init.sh). The build-time `user-data.yaml` is patched at runtime by `startup.sh`.
- **UEFI firmware**: EDK2 for aarch64, OVMF for x86_64. Extracted from the QEMU source tarball during `prepare_qemu_files.sh`.
- **Accelerator detection**: `run.sh` probes for HVF (macOS), KVM (Linux), or falls back to TCG software emulation. Controllable via `IDEKUBE_VM_DISABLE_KVM`.
- **Nginx token auth**: Template-based. `authn.sh` replaces `__IDEKUBE_ACCESS_TOKEN_PLACEHOLDER__` with the real token or writes a permit-all config.
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
| `IDEKUBE_VM_HEADLESS` | `1` | Headless mode (no graphical output) |
| `IDEKUBE_VM_DISABLE_KVM` | `0` | Force software emulation |
| `IDEKUBE_USER_UID` | (unset) | Remap idekube user UID |
| `IDEKUBE_AUTHORIZED_KEYS` | (unset) | Base64-encoded SSH authorized_keys |
| `IDEKUBE_PREFERED_SHELL` | `/bin/bash` | Default shell for idekube user |
| `IDEKUBE_INIT_HOME` | (unset) | Force re-initialize home from /etc/skel |
| `IDEKUBE_ACCESS_TOKEN` | (unset) | Nginx access token (unset = permit all) |
| `IDEKUBE_SSH_PORT` | `22` | Host port for SSH forwarding |
| `IDEKUBE_WEB_PORT` | `80` | Host port for HTTP forwarding |
| `IDEKUBE_MONITOR_PORT` | `23` | Host port for QEMU monitor telnet |

## Networking

QEMU user-mode networking with port forwards:
- SSH: host port -> guest :22
- HTTP: host port -> guest :80
- VNC: host :5901 -> guest :5901
- QEMU monitor: host port -> guest telnet

The featured flavor nginx reverse-proxies internal services: noVNC (:6081), code-server (:3000), WebSocket SSH (:2222), and a health endpoint (:9999).
