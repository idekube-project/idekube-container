"""scripts/ci-resolve-targets.sh: dispatch-input validation and target choice."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "ci-resolve-targets.sh"
needs_docker = pytest.mark.skipif(shutil.which("docker") is None, reason="needs docker buildx")


def resolve(tmp_path, **env):
    out = tmp_path / "out"
    base = {"MATRIX_LINEUP": "universal", "BAKE_OVERRIDE": "docker-bake.staging.hcl", "GITHUB_OUTPUT": str(out)}
    base.update(env)
    full = {k: v for k, v in os.environ.items() if k not in base} | base
    result = subprocess.run(["bash", str(SCRIPT)], cwd=ROOT, env=full, capture_output=True, text=True)
    targets = None
    if out.exists():
        for line in out.read_text().splitlines():
            if line.startswith("targets="):
                targets = line.split("=", 1)[1]
    return result.returncode, targets, result.stderr


@pytest.mark.parametrize(
    "env",
    [
        {"MATRIX_LINEUP": "both"},
        {"BAKE_OVERRIDE": "docker-bake.evil.hcl"},
        {"INPUT_TARGETS": "coder,--set=*.output=type=local"},
        {"INPUT_TARGETS": "Coder"},
        {"INPUT_TARGETS": "coder;id"},
        {"BASE_TAG": "-stable"},
        {"BASE_TAG_ASCEND": "a b"},
    ],
)
def test_rejects_bad_inputs(tmp_path, env):
    code, targets, _ = resolve(tmp_path, **env)
    assert code != 0 and targets is None


def test_defaults_to_the_lineup(tmp_path):
    assert resolve(tmp_path)[:2] == (0, "universal")
    assert resolve(tmp_path, MATRIX_LINEUP="ascend")[:2] == (0, "ascend")


def test_explicit_targets_pass_through(tmp_path):
    assert resolve(tmp_path, INPUT_TARGETS="coder,agent-base-all")[:2] == (0, "coder,agent-base-all")


@needs_docker
def test_skip_base_builds_derived_group(tmp_path):
    assert resolve(tmp_path, SKIP_BASE="true", MATRIX_LINEUP="ascend")[:2] == (0, "ascend-derived")


@needs_docker
def test_skip_base_refuses_targets_with_bases(tmp_path):
    code, targets, err = resolve(tmp_path, SKIP_BASE="true", INPUT_TARGETS="universal")
    assert code != 0 and targets is None
    assert "still builds base images" in err
