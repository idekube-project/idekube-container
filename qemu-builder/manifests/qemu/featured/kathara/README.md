# featured/kathara QEMU image

Ubuntu 24.04 VM with the Kathara network-emulation framework and Docker v28, layered on `featured/base` (`.env`: `IDEKUBE_FROM=featured/base`). Docker starts on every boot; Kathara labs run inside the VM.

## Why forwarded connections used to die ~12 s after boot

Symptom (before the fix): `docker run -p …` an image of this flavor and SSH and HTTP work for a few seconds, then every forwarded connection hangs ("Connection timed out during banner exchange") and never recovers. The same freeze hit the Ansible SSH session whenever dockerd started during provisioning.

Cause, confirmed on the serial console of a wedged VM:

1. QEMU's user-mode network (libslirp) hands a host-forwarded connection to the guest with its **real source address**, unless that address is loopback (then the guest sees `10.0.2.2`). With `docker run -p`, connections reach the QEMU container from Docker's bridge gateway `172.17.0.1`; in Kubernetes, from an ingress or node address.
2. The VM's own dockerd creates `docker0` with Docker's default `172.17.0.1/16` about 12 s into boot.
3. From then on `172.17.0.1` is a local address of the guest, so the guest kernel drops the forwarded SYNs as martians (`IPv4: martian source 10.0.2.15 from 172.17.0.1, on dev enp0s2`). slirp shows the connections stuck in `SYN_SENT`; outbound traffic keeps working.

It was earlier blamed on iptables rule swaps and conntrack flushes; neither is involved (the `policy-rc.d` guard only helped because it kept dockerd, and so docker0, from starting).

## The fix

- **Loopback relay** (`artifacts/startup-scripts/run.sh`, all QEMU images): inside the container, slirp forwards listen on `127.0.0.1` only and socat relays the published ports to them, so the guest always sees `10.0.2.2`, whatever the cluster's address plan.
- **Docker address ranges** (`install.yml`, this flavor): `idekube-docker-network.service` runs before `docker.service` on every boot and merges `bip` and `default-address-pools` into `/etc/docker/daemon.json` (other keys are kept). Defaults stay clear of Docker's own `172.16.0.0/12`/`192.168.0.0/16` and the usual k3s, kubeadm, Calico, kind and Podman ranges, so the VM can still reach those networks:

  | Variable | Default | Format |
  |---|---|---|
  | `IDEKUBE_VM_DOCKER_BIP` | `10.213.0.1/24` | docker0's address with prefix (8-30) |
  | `IDEKUBE_VM_DOCKER_ADDRESS_POOLS` | `10.214.0.0/16:24` | `base/len:size[,...]`, `len <= size <= 30` |

  Set them on the container (Pod env); an empty value means the default. The container's `startup.sh` rejects a malformed value before the VM boots; cloud-init passes valid ones to the guest through `/etc/idekube/runtime-env`.

## Pre-pulling Kathara images

Images are not pulled while the disk is built. Once the VM is up:

```bash
for img in kathara/base kathara/frr kathara/quagga; do
  docker pull docker.io/$img
done
```

To bake them into the disk image, add a branch (e.g. `featured/kathara-prepulled`) that starts from `featured/kathara` via `IDEKUBE_FROM` in its `.env`, start Docker in its playbook, pull, and let the build shut the VM down cleanly.

## If provisioning hangs

1. **`wireshark-common` postinst** calls `dpkg-reconfigure`, which prompts for "non-superusers should capture packets"; without a tty it may block. `DEBIAN_FRONTEND=noninteractive` on the apt task is required (already set).
2. **`unattended-upgrades`** can hold `/var/lib/dpkg/lock-frontend` for minutes in parallel with the playbook's apt tasks. Add `apt: lock_timeout=300` or disable the service before provisioning.
3. For a hang that looks like the one above, check `docker0`'s address (`ip -br addr show docker0`) and the kernel log for `martian source`.

## Reference: playbook task order

```
Update apt cache
Install required system packages (ca-certificates, curl, gnupg, …)
Setup Docker:
  Ensure /etc/apt/keyrings exists
  Add Docker GPG key (with retry)
  Detect dpkg architecture
  Add Docker apt repo
  Resolve latest 5:28.x version via apt-cache madison
  Install policy-rc.d guard (no daemon starts while the image is built)
  apt install docker-ce{,-cli}=<pinned>, containerd.io, buildx, compose
  Remove policy-rc.d
  Add idekube to docker group
Docker address ranges: idekube-docker-network (+ service, docker.service drop-in), enabled
Setup Kathara (amd64): add PPA, apt install kathara
Install network tools (wireshark, tcpdump, …)
Setup netcap (amd64): download + extract + install
Setup Kathara Labs: clone repo only (no docker pull, no daemon start)
Cleanup
```
