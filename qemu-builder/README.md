# idekube-container-qemu-builder

A build and provisioning system for QEMU-based virtual machine images. It constructs provisioned VM disk images from Ubuntu cloud images using cloud-init and Ansible, packages them as multi-arch Docker containers, and supports optional WSL2 conversion. Part of the IDEKube platform for containerized development environments.

## Features

- Multi-architecture support: amd64 (x86_64) and arm64 (aarch64)
- Three-stage image construction: engine base, provisioned disk, runtime container
- Cloud-init integration for both build-time provisioning and runtime configuration
- Ansible-based VM provisioning with per-branch playbooks
- UEFI firmware support (EDK2 for aarch64, OVMF for x86_64)
- Hardware-accelerated virtualization (KVM on Linux, HVF on macOS) with TCG fallback
- Dynamic disk resizing at runtime
- Nginx reverse proxy with token-based access control
- Layered builds via `IDEKUBE_FROM` (inherit provisioned disk from another branch)
- WSL2 rootfs conversion for Windows development
- Multi-arch Docker manifest creation via Buildx

## Prerequisites

- Docker with Buildx support
- QEMU 10.2.0 (compiled in-container or available on host)
- Ansible (`pip install ansible`)
- sshpass (`brew install sshpass` on macOS, `apt install sshpass` on Debian/Ubuntu)
- rsync
- wget, curl, bunzip2
- (Optional) KVM-capable host for accelerated provisioning

## Architecture

### Three-Stage Image Construction

```
Stage 1: QEMU Engine Base (Dockerfile.engine)
  ubuntu:24.04
    -> compile QEMU 10.2.0 from source
    -> bundle UEFI firmware (.fd files)
    -> bundle cloud-init configs + startup scripts
    -> output: idekube-qemu-engine:latest

Stage 2: Provisioned Disk (build_qemu_root.sh)
  Ubuntu cloud image (noble-server-cloudimg-{arch}.img)
    -> boot in QEMU with cloud-init (create idekube user)
    -> rsync rootfs overlays into VM
    -> run Ansible playbook (manifests/qemu/<branch>/install.yml)
    -> copy frontend dist (if present)
    -> clean shutdown
    -> output: .cache/<branch>/images/root.img (qcow2)

Stage 3: Runtime Container (Dockerfile)
  idekube-qemu-engine:latest
    -> COPY provisioned root.img
    -> ENTRYPOINT /startup.sh
    -> output: registry/author/idekube-container-<flavor>[-base]:<tag>-qemu-<arch>
```

### Runtime Initialization Flow

```
docker run <image>
  |
  v
startup.sh (container entrypoint)
  |-- Copy UEFI firmware, configs, root.img to working directory
  |-- Patch user-data.yaml:
  |     - Disable ssh_pwauth
  |     - Add write_files: /etc/idekube/runtime-env (from IDEKUBE_* env vars)
  |     - Add runcmd: vm-init.sh
  |-- exec run.sh
        |
        v
      run.sh (QEMU launcher)
        |-- Detect architecture (aarch64/x86_64)
        |-- Select accelerator (HVF / KVM / TCG)
        |-- Resize disk if IDEKUBE_VM_DISK_SIZE > current
        |-- Generate cloud-init.iso
        |-- exec qemu-system-{arch} with port forwards
              |
              v
            Guest VM boots
              |-- cloud-init writes /etc/idekube/runtime-env
              |-- cloud-init runs vm-init.sh
                    |-- UID remapping (IDEKUBE_USER_UID)
                    |-- Set preferred shell (IDEKUBE_PREFERED_SHELL)
                    |-- Initialize home from /etc/skel
                    |-- Import SSH authorized keys (base64-decoded)
                    |-- Configure nginx token auth (authn.sh)
                    |-- Disable SSH password authentication
                    |-- Execute /etc/idekube/startup.bash/*.sh hooks
                    |-- Restart nginx
```

## Build Pipeline

### 1. Prepare UEFI Firmware Files

Downloads the QEMU source tarball and extracts EDK2 UEFI firmware blobs.

```bash
bash scripts/shell/prepare_qemu_files.sh
```

Output: `.cache/qemu_files/edk2-aarch64-code.fd`, `.cache/qemu_files/edk2-arm-vars.fd`

### 2. Prepare Ubuntu Cloud Images

Downloads Ubuntu 24.04 (Noble) server cloud images for both architectures.

```bash
bash scripts/shell/prepare_qemu_images.sh
```

Output: `.cache/qemu_images/noble-amd64.img`, `.cache/qemu_images/noble-arm64.img`

### 3. Build QEMU Engine Base

Compiles QEMU from source and bundles firmware, configs, and scripts into a base image.

```bash
docker build -t idekube-qemu-engine:latest -f manifests/qemu/Dockerfile.engine .
```

### 4. Provision Root Disk

Boots the cloud image in QEMU, provisions it via cloud-init and Ansible, and produces a qcow2 disk.

```bash
BRANCH=featured/base bash scripts/shell/build_qemu_root.sh
```

The script:
1. Copies the cloud image (or a previously built root.img if `IDEKUBE_FROM` is set)
2. Generates a cloud-init ISO from `artifacts/configs/`
3. Launches QEMU (native first, Docker fallback)
4. Waits for SSH, rsyncs rootfs overlays, runs Ansible playbook
5. Copies frontend dist into nginx root (if present)
6. Performs a clean guest shutdown

Output: `.cache/<branch>/images/root.img`

### 5. Build Runtime Container

Layers the provisioned disk onto the engine base.

```bash
BRANCH=featured/base bash scripts/shell/build_qemu.sh
```

### 6. Create Multi-Arch Manifest

Combines per-arch images into a single manifest.

```bash
BRANCH=featured/base bash scripts/shell/manifest_qemu.sh
```

### 7. Publish

Pushes images to the container registry.

```bash
BRANCH=featured/base bash scripts/shell/publish_qemu.sh
```

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
| `ARCH` | host architecture | Target architecture (`amd64` or `arm64`) |
| `DISTRO` | `noble` | Ubuntu codename for cloud image |
| `IDEKUBE_FROM` | (unset) | Source branch to inherit root.img from |
| `IDEKUBE_VM_MEMORY` | `4G` | VM memory during provisioning |
| `IDEKUBE_VM_CPU` | `2` | VM CPU count during provisioning |
| `IDEKUBE_VM_DISK_SIZE` | `10G` | VM disk size during provisioning |

Additional build args can be supplied in a `.dockerargs` file (KEY=VALUE per line).

### Runtime Environment Variables

| Variable | Default | Description |
|---|---|---|
| `IDEKUBE_VM_MEMORY` | `1G` | VM memory allocation |
| `IDEKUBE_VM_CPU` | `1` | VM CPU count |
| `IDEKUBE_VM_DISK_SIZE` | (unset) | Resize disk on boot (only grows, not shrinks) |
| `IDEKUBE_VM_HEADLESS` | `1` (true) | Headless mode; set to `0` for graphical output |
| `IDEKUBE_VM_DISABLE_KVM` | `0` (false) | Force TCG software emulation |
| `IDEKUBE_USER_UID` | (unset) | Remap the `idekube` user UID inside the VM |
| `IDEKUBE_AUTHORIZED_KEYS` | (unset) | Base64-encoded SSH `authorized_keys` content |
| `IDEKUBE_PREFERED_SHELL` | `/bin/bash` | Default login shell for the `idekube` user |
| `IDEKUBE_INIT_HOME` | (unset) | When set, re-initialize home directory from `/etc/skel` |
| `IDEKUBE_ACCESS_TOKEN` | (unset) | Nginx access token; when unset, all requests are permitted |
| `IDEKUBE_SSH_PORT` | `22` | Container port for SSH forwarding |
| `IDEKUBE_WEB_PORT` | `80` | Container port for HTTP forwarding |
| `IDEKUBE_MONITOR_PORT` | `23` | Container port for QEMU monitor telnet |

### Cloud-Init

The build-time `user-data.yaml` creates the `idekube` user with password `idekube` and sudo access. At runtime, `startup.sh` patches this file:

- Sets `ssh_pwauth: false`
- Adds a `write_files` entry that writes all `IDEKUBE_*` runtime variables to `/etc/idekube/runtime-env`
- Adds a `runcmd` entry that executes `/etc/idekube/vm-init.sh`

## Networking

QEMU uses user-mode (slirp) networking with the following default port forwards:

| Service | Host Port | Guest Port | Notes |
|---|---|---|---|
| SSH | 22 (configurable) | 22 | `IDEKUBE_SSH_PORT` |
| HTTP | 80 (configurable) | 80 | `IDEKUBE_WEB_PORT` |
| VNC | 5901 | 5901 | Fixed in run.sh |
| QEMU Monitor | 23 (configurable) | telnet | `IDEKUBE_MONITOR_PORT` |

When running the container with Docker, map the container ports to host ports:

```bash
docker run -d \
  -p 10022:22 \
  -p 8080:80 \
  -e IDEKUBE_VM_MEMORY=2G \
  -e IDEKUBE_AUTHORIZED_KEYS="$(cat ~/.ssh/id_rsa.pub | base64)" \
  registry/author/idekube-container-featured-base:v1.0.0-qemu
```

### Featured Flavor Nginx Services

The featured build flavor includes an nginx reverse proxy on port 80 that routes to internal services:

| Path | Backend | Auth Required |
|---|---|---|
| `/vnc/` | noVNC at `:6081` | Yes |
| `/coder/` | code-server at `:3000` | Yes |
| `/ssh` | WebSocket SSH at `:2222` | No (uses SSH key auth) |
| `/health` | Health check at `:9999` | No (for k8s probes) |
| `/` | Landing page | Yes |

Access is controlled via `IDEKUBE_ACCESS_TOKEN`, which can be passed as a query parameter, cookie, or `X-IDEKube-Container-Access-Token` header.

## WSL2 Conversion

Convert a provisioned qcow2 disk image to a WSL2-importable rootfs tarball:

```bash
BRANCH=featured/base bash scripts/shell/build_wsl.sh
```

The converter (runs in a Docker container with libguestfs):
1. Copies the qcow2 to a scratch file
2. Applies WSL-specific tweaks via guestfish: writes `/etc/wsl.conf` (enables systemd), blanks `/etc/fstab`, clears `machine-id`, removes SSH host keys, disables cloud-init
3. Exports the rootfs via `virt-tar-out` and gzip

Output: `.cache/<branch>/images/wsl-rootfs.tar.gz`

Import on Windows:
```powershell
wsl --import idekube-featured-base C:\wsl\idekube-featured-base wsl-rootfs.tar.gz
wsl -d idekube-featured-base
```

## Project Structure

```
idekube-container-qemu-builder/
|-- manifests/qemu/
|   |-- Dockerfile              # Runtime container (engine + root.img)
|   |-- Dockerfile.engine       # QEMU engine base (compile QEMU + firmware)
|   |-- <branch>/
|       |-- .env                # Per-branch build environment
|       |-- install.yml         # Ansible playbook for VM provisioning
|
|-- scripts/shell/
|   |-- qemu_common.sh          # Shared variables and arch normalization
|   |-- prepare_qemu_files.sh   # Download QEMU, extract UEFI firmware
|   |-- prepare_qemu_images.sh  # Download Ubuntu cloud images
|   |-- build_qemu_root.sh      # Boot VM, provision via cloud-init + Ansible
|   |-- build_qemu.sh           # Build runtime Docker image
|   |-- build_wsl.sh            # Convert qcow2 to WSL2 rootfs tarball
|   |-- manifest_qemu.sh        # Create multi-arch Docker manifest
|   |-- publish_qemu.sh         # Push images to registry
|
|-- artifacts/
|   |-- configs/
|   |   |-- user-data.yaml      # cloud-init user-data template
|   |   |-- meta-data.yaml      # cloud-init meta-data
|   |-- rootfs/                 # Common rootfs overlays (rsynced into VM)
|   |   |-- authn.sh            # Nginx access-token auth setup
|   |   |-- etc/idekube/
|   |       |-- vm-init.sh      # Runtime VM initialization script
|   |       |-- startup.bash/   # Custom startup hook directory
|   |   |-- etc/nginx/conf.d/
|   |       |-- access_token.conf   # Nginx token auth map template
|   |-- featured/rootfs/        # Feature flavor overlays (XFCE, TurboVNC, noVNC)
|   |-- startup-scripts/
|       |-- startup.sh          # Container entrypoint
|       |-- run.sh              # QEMU launcher
|
|-- tools/utility/
|   |-- cloud-localds/Dockerfile    # cloud-localds utility image
|   |-- qemu-to-wsl/
|       |-- Dockerfile              # WSL converter image (libguestfs)
|       |-- convert.sh              # Conversion script
|
|-- .cache/                     # (gitignored) Build artifacts
    |-- qemu_files/             # QEMU tarball + UEFI firmware
    |-- qemu_images/            # Ubuntu cloud images
    |-- <branch>/images/        # Provisioned root.img per branch
```

## Deployment

### Running the Container

```bash
docker run -d \
  --name idekube-vm \
  -p 10022:22 \
  -p 8080:80 \
  -p 5901:5901 \
  -e IDEKUBE_VM_MEMORY=4G \
  -e IDEKUBE_VM_CPU=2 \
  -e IDEKUBE_VM_DISK_SIZE=20G \
  -e IDEKUBE_AUTHORIZED_KEYS="$(cat ~/.ssh/id_rsa.pub | base64)" \
  -e IDEKUBE_ACCESS_TOKEN=my-secret-token \
  registry/author/idekube-container-featured-base:v1.0.0-qemu
```

### With KVM Acceleration

```bash
docker run -d \
  --device /dev/kvm \
  -p 10022:22 \
  -p 8080:80 \
  -e IDEKUBE_VM_MEMORY=4G \
  registry/author/idekube-container-featured-base:v1.0.0-qemu
```

### SSH Access

```bash
ssh -p 10022 idekube@localhost
```

At runtime, password authentication is disabled. Use `IDEKUBE_AUTHORIZED_KEYS` to inject public keys.
