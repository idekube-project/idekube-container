import os
import subprocess
from pathlib import Path

import pytest

from helpers.images import resolve_image_ref

PROJECT_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(autouse=True)
def fixed_image_env(monkeypatch):
    monkeypatch.setenv("VERSION", "v1.2.3")
    monkeypatch.delenv("GIT_TAG", raising=False)
    monkeypatch.delenv("STAGING_POSTFIX", raising=False)
    monkeypatch.delenv("REGISTRY", raising=False)
    monkeypatch.delenv("AUTHOR", raising=False)


def test_base_image_uses_bare_version_tag():
    assert (
        resolve_image_ref("featured/base")
        == "ghcr.io/idekube-project/idekube-container-featured-base:v1.2.3"
    )


def test_base_image_ascend_tag_keeps_lineup_postfix():
    assert (
        resolve_image_ref("featured/base", "ascend")
        == "ghcr.io/idekube-project/idekube-container-featured-base:v1.2.3-ascend"
    )


def test_application_image_keeps_variant_prefix():
    assert (
        resolve_image_ref("featured/speit")
        == "ghcr.io/idekube-project/idekube-container-featured:speit-v1.2.3"
    )


def test_application_image_ascend_tag_keeps_variant_prefix():
    assert (
        resolve_image_ref("jupyter/speit-ai", "ascend")
        == "ghcr.io/idekube-project/idekube-container-jupyter:speit-ai-v1.2.3-ascend"
    )


def test_staging_postfix_applies_after_lineup(monkeypatch):
    monkeypatch.setenv("STAGING_POSTFIX", "-staging")

    assert (
        resolve_image_ref("coder/base")
        == "ghcr.io/idekube-project/idekube-container-coder-base:v1.2.3-staging"
    )


def test_qemu_base_image_appends_qemu_suffix():
    assert (
        resolve_image_ref("featured/base", image_kind="qemu")
        == "ghcr.io/idekube-project/idekube-container-featured-base:v1.2.3-qemu"
    )


def test_qemu_application_image_appends_qemu_suffix_after_version():
    assert (
        resolve_image_ref("featured/kathara", image_kind="qemu")
        == "ghcr.io/idekube-project/idekube-container-featured:kathara-v1.2.3-qemu"
    )


def test_qemu_shell_common_honors_version_env():
    env = os.environ.copy()
    env.update({"BRANCH": "featured/base", "VERSION": "v1.2.3"})
    env.pop("GIT_TAG", None)

    result = subprocess.run(
        [
            "bash",
            "-c",
            "source scripts/shell/qemu_common.sh; printf '%s\\n' \"$IMAGE_REF\"",
        ],
        cwd=PROJECT_ROOT / "qemu-builder",
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )

    assert (
        result.stdout.strip()
        == "ghcr.io/idekube-project/idekube-container-featured-base:v1.2.3-qemu"
    )
