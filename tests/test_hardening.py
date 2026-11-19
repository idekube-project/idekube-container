"""Container hardening checks — parametrized across all branches.

* Backend services listen on loopback only: nginx (token auth) must be the one
  way in, so another pod or container on the same network cannot reach
  code-server, Jupyter, noVNC, VNC, ttyd, dufs or the agent gateway directly.
* SSH host keys are generated per instance, never shipped in the image.
* The init-container entrypoint actually runs.
"""

from __future__ import annotations

import socket
import subprocess

import pytest

from conftest import attach_log, get_branch_params, get_or_start_container, resolve_and_check
from helpers.constants import DESKTOP_BRANCHES, get_expected_health
from helpers.containers import container_labels

# Reachable from the network on purpose: SSH bridge (key auth) and the health
# endpoint that Kubernetes probes hit directly.
NETWORK_FACING_PORTS = {2222, 9999}
# Raw VNC server behind noVNC on desktop images (passwordless).
VNC_PORT = 5901


def pytest_generate_tests(metafunc):
    if "branch" in metafunc.fixturenames:
        metafunc.parametrize("branch", get_branch_params(metafunc.config), indirect=False)


def _container_ip(container_id: str) -> str:
    result = subprocess.run(
        ["docker", "inspect", "--format",
         "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", container_id],
        capture_output=True, text=True, check=True,
    )
    addresses = result.stdout.split()
    if not addresses:
        pytest.skip("container has no bridge IP address")
    return addresses[0]


def _tcp_connects(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=3):
            return True
    except OSError:
        return False


def _backend_ports(branch: str) -> list[int]:
    ports = {
        svc["port"]
        for svc in get_expected_health(branch)["services"].values()
        if svc["port"] not in NETWORK_FACING_PORTS
    }
    if branch in DESKTOP_BRANCHES:
        ports.add(VNC_PORT)
    return sorted(ports)


class TestBackendsLoopbackOnly:
    def test_backends_unreachable_from_network(self, branch, container_pool, output_dir, lineup, request):
        image_ref = resolve_and_check(branch, lineup)
        cm = get_or_start_container(container_pool, branch, image_ref, output_dir)
        attach_log(request.node, cm)
        ip = _container_ip(cm.container_id)

        exposed = []
        for port in _backend_ports(branch):
            # Positive control: the service is up inside the container ...
            inside = cm.exec_run(f"exec 3<>/dev/tcp/127.0.0.1/{port}")
            assert inside.returncode == 0, f"port {port} is not listening on 127.0.0.1 in the container"
            # ... but not on the container's network address.
            if _tcp_connects(ip, port):
                exposed.append(port)
        assert not exposed, f"backend ports reachable from the network at {ip}: {exposed}"

    def test_health_port_still_network_facing(self, branch, container_pool, output_dir, lineup, request):
        """Kubernetes probes hit :9999 directly, so it must stay reachable."""
        image_ref = resolve_and_check(branch, lineup)
        cm = get_or_start_container(container_pool, branch, image_ref, output_dir)
        attach_log(request.node, cm)
        assert _tcp_connects(_container_ip(cm.container_id), 9999)


class TestSshHostKeys:
    def test_image_ships_no_host_keys(self, branch, lineup):
        image_ref = resolve_and_check(branch, lineup)
        result = subprocess.run(
            ["docker", "run", "--rm", *container_labels(), "--entrypoint", "/bin/sh", image_ref,
             "-c", "ls /etc/ssh/ssh_host_* 2>/dev/null || true"],
            capture_output=True, text=True, timeout=120,
        )
        assert result.stdout.strip() == "", f"image contains SSH host keys:\n{result.stdout}"

    def test_host_keys_differ_between_containers(self, branch, container_pool, output_dir, lineup, request):
        image_ref = resolve_and_check(branch, lineup)
        first = get_or_start_container(container_pool, branch, image_ref, output_dir)
        second = get_or_start_container(
            container_pool, branch, image_ref, output_dir,
            extra_env={"IDEKUBE_ACCESS_TOKEN": "Hardening.Token-1"},
            pool_key=f"{branch}:hostkeys",
        )
        attach_log(request.node, first)

        def fingerprint(cm) -> str:
            result = cm.exec_run(["ssh-keygen", "-lf", "/etc/ssh/ssh_host_ed25519_key.pub"])
            assert result.returncode == 0, f"no ed25519 host key: {result.stderr}"
            return result.stdout.split()[1]

        assert fingerprint(first) != fingerprint(second), "two containers share an SSH host key"


class TestInitContainer:
    def test_init_container_mode_runs(self, branch, lineup):
        """I_AM_INIT_CONTAINER used to call a misnamed script and exit 127."""
        image_ref = resolve_and_check(branch, lineup)
        result = subprocess.run(
            ["docker", "run", "--rm", *container_labels(), "-e", "I_AM_INIT_CONTAINER=true", image_ref],
            capture_output=True, text=True, timeout=120,
        )
        output = result.stdout + result.stderr
        # Without a /rootfs volume the init script exits cleanly without copying.
        assert result.returncode == 0, f"exit {result.returncode}:\n{output[-2000:]}"
        assert "/rootfs is not mounted to another volume" in output, output[-2000:]
