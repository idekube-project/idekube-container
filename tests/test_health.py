"""Tests for the /health endpoint — parametrized across all branches."""

from __future__ import annotations

import time

import pytest
import requests

from conftest import attach_log, get_branch_params, get_or_start_container, resolve_and_check
from helpers.constants import get_expected_health


def pytest_generate_tests(metafunc):
    if "branch" in metafunc.fixturenames:
        metafunc.parametrize("branch", get_branch_params(metafunc.config), indirect=False)


class TestHealthEndpoint:
    """Validate /health returns correct JSON for every image."""

    def test_health_returns_200(self, branch, container_pool, output_dir, lineup, request):
        image_ref = resolve_and_check(branch, lineup)
        cm = get_or_start_container(container_pool, branch, image_ref, output_dir)
        attach_log(request.node, cm)

        resp = requests.get(f"{cm.base_url}/health", timeout=10)
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        data = resp.json()
        assert "status" in data
        assert "services" in data
        assert data["status"] in ("healthy", "degraded")

    def test_health_has_correct_services(self, branch, container_pool, output_dir, lineup, request):
        image_ref = resolve_and_check(branch, lineup)
        cm = get_or_start_container(container_pool, branch, image_ref, output_dir)
        attach_log(request.node, cm)

        resp = requests.get(f"{cm.base_url}/health", timeout=10)
        data = resp.json()
        expected = get_expected_health(branch)
        assert set(expected["services"]) == set(data["services"]), (
            f"Expected services {set(expected['services'])}, got {set(data['services'])}"
        )

    def test_health_has_entry(self, branch, container_pool, output_dir, lineup, request):
        image_ref = resolve_and_check(branch, lineup)
        cm = get_or_start_container(container_pool, branch, image_ref, output_dir)
        attach_log(request.node, cm)

        resp = requests.get(f"{cm.base_url}/health", timeout=10)
        data = resp.json()
        assert "entry" in data and data["entry"]

    def test_health_no_auth_required(self, branch, container_pool, output_dir, lineup, request):
        """Even containers with auth should expose /health without auth."""
        image_ref = resolve_and_check(branch, lineup)
        cm = get_or_start_container(container_pool, branch, image_ref, output_dir)
        attach_log(request.node, cm)

        resp = requests.get(f"{cm.base_url}/health", timeout=10)
        assert resp.status_code == 200


# How long programs get to settle (supervisord retries failing ones first).
PROGRAM_SETTLE_TIMEOUT = 60

# Programs whose supervisord entry is a launcher that daemonizes the real
# server and exits 0 (TurboVNC's vncserver without -fg). For these, EXITED is
# expected and the daemon process itself must be alive instead.
DAEMONIZING_PROGRAMS = {"turbovnc": "Xvnc"}


def _daemon_alive(cm, program: str, state: str) -> bool:
    daemon = DAEMONIZING_PROGRAMS.get(program)
    return state == "EXITED" and daemon is not None and cm.exec_run(["pgrep", "-x", daemon]).returncode == 0


class TestSupervisorPrograms:
    """Every supervisord program must be up, not just the ones /health probes.

    /health only covers the user-facing services listed in health.json, so a
    background program (e.g. the hermes gateway) could be dead without any
    other test noticing.
    """

    def test_all_programs_running(self, branch, container_pool, output_dir, lineup, request):
        image_ref = resolve_and_check(branch, lineup)
        cm = get_or_start_container(container_pool, branch, image_ref, output_dir)
        attach_log(request.node, cm)

        deadline = time.monotonic() + PROGRAM_SETTLE_TIMEOUT
        while True:
            result = cm.exec_run(["supervisorctl", "status"])
            states = {
                fields[0]: fields[1]
                for fields in (line.split() for line in result.stdout.splitlines())
                if len(fields) >= 2
            }
            not_running = {
                name: state
                for name, state in states.items()
                if state != "RUNNING" and not _daemon_alive(cm, name, state)
            }
            if (states and not not_running) or time.monotonic() > deadline:
                break
            time.sleep(2)

        assert states, f"supervisorctl status returned nothing: {result.stdout}{result.stderr}"
        assert not not_running, f"supervisor programs not running: {not_running}\n{result.stdout}"
