"""Image tag resolution and availability detection.

The bake-driven build system tags images per-flavor:
  ghcr.io/idekube-project/idekube-container-<flavor>:<variant>-<version>[-ascend][-staging]

This helper produces the same refs that docker-bake.hcl produces, so tests can
locate the locally-built or pushed images.
"""

from __future__ import annotations

import os
import platform
import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]

# Lineup -> branches. Mirrors docker-bake.hcl groups "base" / "ascend".
LINEUP_BRANCHES: dict[str, list[str]] = {
    "base": [
        "featured/base",
        "featured/speit",
        "featured/speit-ai",
        "featured/dind",
        "featured/kathara",
        "featured/ros2",
        "coder/base",
        "coder/conda",
        "jupyter/base",
        "jupyter/speit-ai",
        "agent/base",
        "agent/openclaw",
        "agent/hermes",
    ],
    "ascend": [
        "featured/base",
        "featured/speit-ai",
        "jupyter/base",
        "jupyter/speit-ai",
        "jupyter/speit-ascendai",
    ],
}

# Branch -> registry repo name (matches the per-flavor GHCR scheme).
# Base variants get their own *-base repos; non-base variants share the flavor repo.
BRANCH_REPO: dict[str, str] = {
    "featured/base":          "idekube-container-featured-base",
    "featured/speit":         "idekube-container-featured",
    "featured/speit-ai":      "idekube-container-featured",
    "featured/dind":          "idekube-container-featured",
    "featured/kathara":       "idekube-container-featured",
    "featured/ros2":          "idekube-container-featured",
    "coder/base":             "idekube-container-coder-base",
    "coder/conda":            "idekube-container-coder",
    "jupyter/base":           "idekube-container-jupyter-base",
    "jupyter/speit-ai":       "idekube-container-jupyter",
    "jupyter/speit-ascendai": "idekube-container-jupyter",
    "agent/base":             "idekube-container-agent-base",
    "agent/openclaw":         "idekube-container-agent",
    "agent/hermes":           "idekube-container-agent",
}

# Branch -> depends_on. Mirrors the docker-bake.hcl target-context graph.
BRANCH_DEPENDS_ON: dict[str, str | None] = {
    "featured/base":          None,
    "featured/speit":         "featured/base",
    "featured/speit-ai":      "featured/base",
    "featured/dind":          "featured/base",
    "featured/kathara":       "featured/dind",
    "featured/ros2":          "featured/base",
    "coder/base":             None,
    "coder/conda":            "coder/base",
    "jupyter/base":           None,
    "jupyter/speit-ai":       "jupyter/base",
    "jupyter/speit-ascendai": "jupyter/base",
    "agent/base":             None,
    "agent/openclaw":         "agent/base",
    "agent/hermes":           "agent/base",
}


def detect_git_tag() -> str:
    """Match docker-bake.hcl's VERSION variable resolution."""
    env_tag = os.environ.get("VERSION") or os.environ.get("GIT_TAG")
    if env_tag:
        return env_tag
    try:
        result = subprocess.run(
            ["git", "tag", "--list", "--sort=-v:refname"],
            capture_output=True,
            text=True,
            check=True,
            cwd=PROJECT_ROOT,
        )
        tags = result.stdout.strip().splitlines()
        return tags[0] if tags else "latest"
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "latest"


def detect_arch() -> str:
    machine = platform.machine()
    mapping = {
        "x86_64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
        "amd64": "amd64",
    }
    return mapping.get(machine, machine)


def get_lineup_branches(lineup: str) -> list[str]:
    if lineup not in LINEUP_BRANCHES:
        raise ValueError(f"Unknown lineup: {lineup}")
    return list(LINEUP_BRANCHES[lineup])


def branch_to_variant(branch: str) -> str:
    """Extract variant tag prefix: 'featured/speit' -> 'speit'."""
    return branch.split("/", 1)[1]


def branch_to_slug(branch: str) -> str:
    """Legacy slug form retained for compatibility: 'featured/base' -> 'featured-base'."""
    return branch.replace("/", "-")


def resolve_image_ref(branch: str, lineup: str = "base") -> str:
    """Compute the full image ref produced by docker buildx bake.

    Format: {registry}/{author}/{repo}:{variant}-{version}{lineup_postfix}{staging_postfix}

    - lineup_postfix is "-ascend" for the ascend lineup, "" otherwise.
    - staging_postfix is read from STAGING_POSTFIX env var (matches bake).
    """
    if branch not in BRANCH_REPO:
        raise ValueError(f"Unknown branch: {branch}")

    registry = os.environ.get("REGISTRY", "ghcr.io")
    author = os.environ.get("AUTHOR", "idekube-project")
    repo = BRANCH_REPO[branch]
    version = detect_git_tag()
    lineup_postfix = "-ascend" if lineup == "ascend" else ""
    staging_postfix = os.environ.get("STAGING_POSTFIX", "")

    variant = branch_to_variant(branch)
    tag = f"{variant}-{version}{lineup_postfix}{staging_postfix}"
    return f"{registry}/{author}/{repo}:{tag}"


def is_image_available(image_ref: str) -> bool:
    """Check if a Docker image exists locally."""
    try:
        result = subprocess.run(
            ["docker", "image", "inspect", image_ref],
            capture_output=True,
            text=True,
        )
        return result.returncode == 0
    except FileNotFoundError:
        return False


def get_flavor(branch: str) -> str:
    """Extract flavor from branch name: 'featured/base' -> 'featured'."""
    return branch.split("/")[0]


def get_image_dependencies() -> dict[str, str | None]:
    """Return {branch: depends_on} mapping (mirror of docker-bake.hcl chain)."""
    return dict(BRANCH_DEPENDS_ON)
