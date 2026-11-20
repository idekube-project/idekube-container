"""IDEKUBE_* environment parsing (idekube-env.sh), shared by the containers,
the QEMU container entrypoint and the QEMU guest.

A templated Kubernetes manifest renders unset values as empty strings and
booleans as "false"; both must mean "off", and a typo must stop the container
instead of being read as "set" (IDEKUBE_VM_RESET_DISK=false used to replace
the VM's disk).
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
HELPERS = [
    ROOT / "artifacts/rootfs/usr/local/lib/idekube/env.sh",
    ROOT / "qemu-builder/artifacts/startup-scripts/idekube-env.sh",
]


def call(helper: Path, function: str, value: str | None, *args: str) -> subprocess.CompletedProcess:
    env = {"PATH": "/usr/bin:/bin"}
    if value is not None:
        env["V"] = value
    return subprocess.run(
        ["bash", "-c", f'source "$0"; {function} V "$@"', str(helper), *args],
        capture_output=True, text=True, env=env, check=False,
    )


def test_copies_are_identical():
    assert HELPERS[0].read_bytes() == HELPERS[1].read_bytes(), (
        "artifacts/rootfs/usr/local/lib/idekube/env.sh and "
        "qemu-builder/artifacts/startup-scripts/idekube-env.sh must stay identical"
    )


@pytest.mark.parametrize("helper", HELPERS, ids=["image", "qemu"])
@pytest.mark.parametrize(
    "value,default,expected",
    [
        (None, "0", "0"),
        (None, "1", "1"),
        ("", "1", "1"),
        ("  ", "0", "0"),
        ("true", "0", "1"),
        ("TRUE", "0", "1"),
        (" yes ", "0", "1"),
        ("On", "0", "1"),
        ("1", "0", "1"),
        ("false", "1", "0"),
        ("False", "1", "0"),
        ("no", "1", "0"),
        ("OFF", "1", "0"),
        ("0", "1", "0"),
    ],
)
def test_bool_accepts(helper, value, default, expected):
    result = call(helper, "idekube_bool", value, default)
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{expected}\n"


@pytest.mark.parametrize("helper", HELPERS, ids=["image", "qemu"])
@pytest.mark.parametrize("value", ["ture", "2", "-1", "enabled", "true false", "y"])
def test_bool_rejects(helper, value):
    result = call(helper, "idekube_bool", value)
    assert result.returncode == 2
    assert result.stdout == ""
    assert f"V='{value.strip()}' is not a boolean" in result.stderr


@pytest.mark.parametrize(
    "value,expected,rc",
    [(None, "25", 0), ("", "25", 0), ("0", "0", 0), ("08", "8", 0), ("90", "90", 0),
     ("soon", "", 2), ("-5", "", 2), ("1.5", "", 2)],
)
def test_uint(value, expected, rc):
    result = call(HELPERS[1], "idekube_uint", value, "25")
    assert result.returncode == rc, result.stderr
    assert result.stdout.strip() == expected


@pytest.mark.parametrize(
    "value,expected",
    [(None, "10.213.0.1/24"), ("", "10.213.0.1/24"), ("10.99.0.1/24", "10.99.0.1/24"),
     (" 172.30.0.1/16 ", "172.30.0.1/16")],
)
def test_docker_bip_accepts(value, expected):
    result = call(HELPERS[1], "idekube_docker_bip", value, "10.213.0.1/24")
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{expected}\n"


@pytest.mark.parametrize(
    "value", ["172.17.0.1", "10.0.0.1/31", "10.0.0.1/7", "256.0.0.1/24", "10.0.0/24", "fd00::1/64"],
)
def test_docker_bip_rejects(value):
    result = call(HELPERS[1], "idekube_docker_bip", value, "10.213.0.1/24")
    assert result.returncode == 2
    assert "is not an IPv4 address" in result.stderr


@pytest.mark.parametrize(
    "value,expected",
    [(None, "10.214.0.0/16:24"), ("", "10.214.0.0/16:24"),
     ("10.100.0.0/16:24", "10.100.0.0/16:24"),
     ("10.100.0.0/16:24, 10.101.0.0/16:26", "10.100.0.0/16:24,10.101.0.0/16:26")],
)
def test_docker_pools_accepts(value, expected):
    result = call(HELPERS[1], "idekube_docker_pools", value, "10.214.0.0/16:24")
    assert result.returncode == 0, result.stderr
    assert result.stdout == f"{expected}\n"


@pytest.mark.parametrize(
    "value",
    ["10.214.0.0/16", "10.214.0.0/16:8", "10.214.0.0/16:31", "10.214.0.0:24", ",10.1.0.0/16:24",
     "10.214.0.0/16:x"],
)
def test_docker_pools_rejects(value):
    result = call(HELPERS[1], "idekube_docker_pools", value, "10.214.0.0/16:24")
    assert result.returncode == 2
    assert "is not base/len:size" in result.stderr
