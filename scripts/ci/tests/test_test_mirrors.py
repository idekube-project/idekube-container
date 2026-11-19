"""tests/helpers/images.py mirrors docker-bake.hcl; fail when the two drift."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(ROOT / "tests"))

import bakeplan  # noqa: E402
from helpers.images import BRANCH_REPO, LINEUP_BRANCHES  # noqa: E402

pytestmark = pytest.mark.skipif(shutil.which("docker") is None, reason="needs docker buildx")


def test_lineups_and_repos_match_bake():
    plan = bakeplan.bake_print(["universal", "ascend"], version="x", staging=False)
    seen: dict[str, set[str]] = {"universal": set(), "ascend": set()}
    for name, target in bakeplan.published_targets(plan).items():
        branch = bakeplan.target_branch(target)
        repo = bakeplan.split_ref(target["tags"][0])[0].rsplit("/", 1)[1]
        assert BRANCH_REPO.get(branch) == repo, f"{name}: tests map {branch} to {BRANCH_REPO.get(branch)}, bake to {repo}"
        seen[bakeplan.target_lineup(name)].add(branch)
    for lineup, branches in seen.items():
        assert set(LINEUP_BRANCHES[lineup]) == branches, f"{lineup}: tests {sorted(LINEUP_BRANCHES[lineup])}, bake {sorted(branches)}"
