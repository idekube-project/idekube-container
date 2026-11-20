# idekube-container-qemu-builder

A build and provisioning system for QEMU-based virtual machine images. It constructs provisioned VM disk images from Ubuntu cloud images using cloud-init and Ansible, packages them as multi-arch Docker containers, and supports optional WSL2 conversion. Part of the IDEKube platform for containerized development environments.

## Features

- Multi-architecture support: amd64 (x86_64) and arm64 (aarch64)
- Three-stage image construction: engine base, provisioned disk, runtime container
- Cloud-init integration for both build-time provisioning and runtime configuration
- Ansible-based VM provisioning with per-branch playbooks
- UEFI firmware support (EDK2 for aarch64, OVMF for x86_64)
- Hardware-accelerated virtualization (KVM on Linux, HVF on macOS) with TCG fallback, or KVM required (`IDEKUBE_VM_REQUIRE_KVM`)
- Clean guest power-off when the container is stopped (`docker stop`, Pod deletion)
- Configuration through environment variables that a Kubernetes template can render: empty means unset, malformed values stop the container before the disk is touched
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
  |-- Validate the IDEKUBE_* configuration; exit with a message on a bad value
  |-- Copy UEFI firmware and configs; seed root.img only if absent (or IDEKUBE_VM_RESET_DISK=true)
  |-- Patch user-data.yaml:
  |     - Disable ssh_pwauth, drop chpasswd, lock the password
  |     - Add write_files: /etc/idekube/runtime-env (from IDEKUBE_* env vars)
  |     - Add runcmd: vm-init.sh
  |-- exec run.sh
        |
        v
      run.sh (QEMU launcher and supervisor, the container's main process)
        |-- Detect architecture (aarch64/x86_64)
        |-- Select accelerator (HVF / KVM if /dev/kvm opens read-write / TCG unless KVM is required)
        |-- Resize disk if IDEKUBE_VM_DISK_SIZE > current
        |-- Generate cloud-init.iso
        |-- Start the socat relays (:22, :80 -> 127.0.0.1 slirp forwards)
        |-- Start qemu-system-{arch} (monitor socket + private QMP socket)
        |-- On SIGTERM: QMP system_powerdown, wait IDEKUBE_VM_SHUTDOWN_TIMEOUT, then stop QEMU
              |
              v
            Guest VM boots
              |-- cloud-init writes /etc/idekube/runtime-env
              |-- idekube-authn.service renders nginx token auth (authn.sh),
              |   then nginx starts (it Requires= the service)
              |-- (featured/kathara) idekube-docker-network.service sets Docker's
              |   address ranges, then docker starts
              |-- cloud-init runs vm-init.sh
                    |-- UID remapping (IDEKUBE_USER_UID)
                    |-- Set preferred shell (IDEKUBE_PREFERED_SHELL)
                    |-- Initialize home from /etc/skel
                    |-- Import SSH authorized keys (base64-decoded)
                    |-- Lock the password, disable SSH password authentication
                    |-- Execute /etc/idekube/startup.bash/*.sh hooks
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

### 3. Prepare Guest Tools

Builds what the playbooks copy into the VM: the `idekube-healthcheck` binary for both architectures and the landing page (the same `node:22-alpine` build as the images' `frontend-builder` stage, versioned `<VERSION>-<frontend hash>`).

```bash
bash scripts/shell/prepare_qemu_tools.sh      # make qemu-tools
```

Output: `.cache/qemu_tools/idekube-healthcheck.{amd64,arm64}`, `.cache/qemu_tools/frontend-dist/`

### 3b. Build QEMU Engine Base

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
4. Waits for SSH, rsyncs the rootfs layers (shared container files, then VM-only overrides), runs the Ansible playbook with every build arg of the flavor's base target in `../docker-bake.hcl` as variables (`websocat_version`, `coder_version`, `miniconda_version`, …), so the VM gets the same upstream versions as the container images and the playbooks pin none
5. Copies the landing page from step 3 into nginx's root (required)
6. Performs a clean guest shutdown

Output: `.cache/<branch>/images/root.img`

### 5. Build Runtime Container

Layers the provisioned disk onto the engine base.

```bash
BRANCH=featured/base bash scripts/shell/build_qemu.sh
```

### 5b. Smoke Test

Boots the runtime image three times on one volume (needs KVM): invalid configuration is refused; auth, landing page, proxied services, SSH and hardening; a clean power-off on `docker stop` right after a write, with the file still there on the next boot; `IDEKUBE_VM_RESET_DISK`; for `featured/kathara`, Docker on its address ranges. The repository's pytest suite does not cover QEMU images.

```bash
BRANCH=featured/base bash scripts/shell/test_qemu.sh      # make qemu-test BRANCH=featured/base
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

Booleans (marked *bool*) take `true`/`false`, `1`/`0`, `yes`/`no` or `on`/`off` in any case. An empty value means unset (a Helm template renders an omitted value that way). Any other value, and a malformed number or address, makes `startup.sh` exit with a message naming the variable, before the disk is touched; in Kubernetes the Pod goes into CrashLoopBackOff instead of running with a guessed setting.

| Variable | Default | Description |
|---|---|---|
| `IDEKUBE_VM_MEMORY` | `1G` | VM memory allocation |
| `IDEKUBE_VM_CPU` | `1` | VM CPU count |
| `IDEKUBE_VM_DISK_SIZE` | (unset) | Resize disk on boot (only grows, not shrinks) |
| `IDEKUBE_VM_HEADLESS` | `true` | *bool*. Headless mode; `false` for graphical output |
| `IDEKUBE_VM_DISABLE_KVM` | `false` | *bool*. Force TCG software emulation |
| `IDEKUBE_VM_REQUIRE_KVM` | `false` | *bool*. Refuse to start without usable KVM (`/dev/kvm` must open read-write) instead of falling back to slow software emulation. Conflicts with `IDEKUBE_VM_DISABLE_KVM` |
| `IDEKUBE_VM_RESET_DISK` | `false` | *bool*. `true` replaces an existing `root.img` in `/var/lib/data` with the image's pristine disk; anything that parses as false keeps it |
| `IDEKUBE_VM_SHUTDOWN_TIMEOUT` | `25` | Seconds to wait for the guest to power off after SIGTERM before QEMU is stopped. Keep it below the stop grace period (see Kubernetes) |
| `IDEKUBE_USER_UID` | (unset) | Remap the `idekube` user UID inside the VM |
| `IDEKUBE_AUTHORIZED_KEYS` | (unset) | Base64-encoded SSH `authorized_keys` content |
| `IDEKUBE_PREFERED_SHELL` | `/bin/bash` | Default login shell for the `idekube` user |
| `IDEKUBE_INIT_HOME` | `false` | *bool*. Re-initialize the home directory from `/etc/skel` (an empty home always is) |
| `IDEKUBE_ACCESS_TOKEN` | (unset) | Nginx access token (letters, digits, `.`, `_`, `-`); when unset, all requests are permitted. An invalid token keeps nginx from starting |
| `IDEKUBE_VM_DOCKER_BIP` | `10.213.0.1/24` | featured/kathara: address of the VM's `docker0` |
| `IDEKUBE_VM_DOCKER_ADDRESS_POOLS` | `10.214.0.0/16:24` | featured/kathara: Docker's `default-address-pools`, `base/len:size[,...]` |
| `IDEKUBE_SSH_PORT` | `22` | Container port for SSH forwarding |
| `IDEKUBE_WEB_PORT` | `80` | Container port for HTTP forwarding (61022 and 61080 are reserved for the relay) |
| `IDEKUBE_MONITOR_SOCKET` | `./qemu-monitor.sock` | Unix socket for the QEMU monitor (relative to `/var/lib/data`) |
| `IDEKUBE_MONITOR_PORT` | (unset) | Opt-in telnet monitor, bound to `127.0.0.1` only (replaces the socket) |
| `IDEKUBE_VM_HOSTFWD_ADDR` | (empty) | Empty: forwards through the loopback relay (the container). Set: slirp listens on that address directly (the build script's native mode uses `127.0.0.1`) |

### Cloud-Init

The build-time `user-data.yaml` creates the `idekube` user with password `idekube` and sudo access. At runtime, `startup.sh` patches this file:

- Sets `ssh_pwauth: false`, removes the `chpasswd` block and sets `lock_passwd: true` (`vm-init.sh` also runs `passwd -l idekube`): key SSH and the passwordless sudo rule keep working, but the build password no longer opens the serial console
- Adds a `write_files` entry that writes all `IDEKUBE_*` runtime variables to `/etc/idekube/runtime-env`
- Adds a `runcmd` entry that executes `/etc/idekube/vm-init.sh`
- Writes a fresh `instance-id` to `meta-data.yaml`, so cloud-init re-applies these settings on every start even when `/var/lib/data` keeps the disk (SSH host keys are regenerated each start as a result)

nginx access-token auth is rendered by `idekube-authn.service` on every boot, before nginx starts; nginx does not start if the token is invalid.

## Networking

QEMU uses user-mode (slirp) networking with the following port forwards:

| Service | Container Port | Guest Port | Notes |
|---|---|---|---|
| SSH | 22 (configurable) | 22 | `IDEKUBE_SSH_PORT` |
| HTTP | 80 (configurable) | 80 | `IDEKUBE_WEB_PORT` |

In the container the forwards go through a loopback relay: socat listens on the container ports and connects to slirp forwards bound to `127.0.0.1:61022`/`127.0.0.1:61080`. libslirp passes a forwarded connection's real source address into the guest unless it is loopback (then the guest sees `10.0.2.2`). Without the relay the guest would see Docker's bridge gateway or an ingress Pod IP, and any guest network covering that address breaks the forward: in `featured/kathara`, the VM's `docker0` (Docker's default `172.17.0.1/16`) made every forwarded connection from `172.17.0.1` a martian ~12 s into boot. With the relay the guest always sees `10.0.2.2`; the price is that guest logs (nginx, sshd) show `10.0.2.2` instead of the client address, which was the Docker bridge or ingress address anyway. A relay that dies stops the container, so the orchestrator restarts it.

VNC (5901) is not forwarded: it has no password, so it only listens inside the guest and is reached through the gateway's `/vnc` route. The QEMU monitor is a unix socket (`IDEKUBE_MONITOR_SOCKET`), never a network port; reach it with `docker exec -it <container> socat - UNIX-CONNECT:/var/lib/data/qemu-monitor.sock`. `run.sh` uses a separate QMP socket (`/var/lib/data/qemu-qmp.sock`) to power the guest off.

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
|   |-- rootfs/                 # VM-only files (etc/idekube/vm-init.sh)
|   |-- featured/rootfs/        # VM-only desktop overrides (Chromium flags, TurboVNC launch)
|                               # Everything else comes from ../artifacts/rootfs and
|                               # ../images/<flavor>-base/... (see sync_rootfs in qemu_common.sh)
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
  --stop-timeout 35 \
  -v idekube-vm:/var/lib/data \
  -p 10022:22 \
  -p 8080:80 \
  -e IDEKUBE_VM_MEMORY=4G \
  -e IDEKUBE_VM_REQUIRE_KVM=true \
  registry/author/idekube-container-featured-base:v1.0.0-qemu
```

`docker stop` waits 10 s by default before SIGKILL; `--stop-timeout` (or `docker stop -t`) above `IDEKUBE_VM_SHUTDOWN_TIMEOUT` lets the guest power off cleanly. A volume on `/var/lib/data` keeps the VM disk across container restarts.

### Kubernetes

```yaml
spec:
  terminationGracePeriodSeconds: 40        # > IDEKUBE_VM_SHUTDOWN_TIMEOUT (25)
  containers:
    - name: vm
      image: ghcr.io/idekube-project/idekube-container-featured:kathara-v1.0.0-qemu
      ports:
        - { containerPort: 22 }
        - { containerPort: 80 }
      env:
        - { name: IDEKUBE_VM_MEMORY, value: "4G" }
        - { name: IDEKUBE_VM_CPU, value: "2" }
        - { name: IDEKUBE_VM_REQUIRE_KVM, value: "true" }     # fail instead of crawling on TCG
        - { name: IDEKUBE_VM_RESET_DISK, value: "false" }     # only "true" resets the disk
        - { name: IDEKUBE_ACCESS_TOKEN, valueFrom: { secretKeyRef: { name: vm-token, key: token } } }
        - { name: IDEKUBE_AUTHORIZED_KEYS, value: "<base64>" }
        # featured/kathara only, when the defaults overlap networks the VM must reach:
        - { name: IDEKUBE_VM_DOCKER_BIP, value: "10.213.0.1/24" }
        - { name: IDEKUBE_VM_DOCKER_ADDRESS_POOLS, value: "10.214.0.0/16:24" }
      resources:
        limits:
          devices.kubevirt.io/kvm: "1"             # or whatever exposes /dev/kvm on your nodes
      volumeMounts:
        - { name: vm-disk, mountPath: /var/lib/data }
```

- **Shutdown**: on Pod deletion, node drain or a rolling update, the kubelet sends SIGTERM; `run.sh` asks the guest for an ACPI power-off and waits `IDEKUBE_VM_SHUTDOWN_TIMEOUT` seconds before stopping QEMU. `terminationGracePeriodSeconds` (default 30) must be larger, or the kubelet's SIGKILL cuts the shutdown short. No `preStop` hook is needed.
- **KVM**: `/dev/kvm` must be in the container (a device plugin, or `privileged`). Set `IDEKUBE_VM_REQUIRE_KVM=true` in classrooms: a node pool without usable KVM then fails visibly instead of starting every VM in software emulation.
- **Templates**: render unset values as empty strings or leave them out; both mean the default. Booleans from `values.yaml` render as `true`/`false`, which is what the image expects.
- **Networking**: the guest never sees the ingress or Pod source addresses (loopback relay), so the cluster's address plan does not matter for the forwards. For `featured/kathara`, move `IDEKUBE_VM_DOCKER_*` only if `10.213.0.0/24`/`10.214.0.0/16` overlap something the VM must reach.

### SSH Access

```bash
ssh -p 10022 idekube@localhost
```

At runtime, password authentication is disabled. Use `IDEKUBE_AUTHORIZED_KEYS` to inject public keys.
