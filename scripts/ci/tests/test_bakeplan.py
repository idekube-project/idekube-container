"""Unit tests for scripts/ci/bakeplan.py (no docker, no network).

Fixtures are trimmed `docker buildx bake --print` outputs for the targets
`coder agent-openclaw-all` with VERSION=v1.2.3, so agent-base-* appear as
dependency-only (cacheonly) targets.
"""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import bakeplan  # noqa: E402

SHA = "a" * 40
STAGING = json.loads((HERE / "fixtures" / "plan-staging.json").read_text())
RELEASE = json.loads((HERE / "fixtures" / "plan-release.json").read_text())
PUBLISHED = ["agent-openclaw-ascend", "agent-openclaw-universal", "coder-base", "coder-conda"]


def index(digest: str, *platforms: str) -> dict:
    manifests = []
    for p in platforms:
        os_, arch, *variant = p.split("/")
        entry = {"platform": {"os": os_, "architecture": arch}}
        if variant:
            entry["platform"]["variant"] = variant[0]
        manifests.append(entry)
    manifests.append({"platform": {"os": "unknown", "architecture": "unknown"}})  # attestation
    return {"digest": digest, "manifests": manifests}


class FakeRegistry:
    def __init__(self, tags: dict[str, dict] | None = None):
        self.tags = dict(tags or {})

    def __call__(self, ref: str):
        return self.tags.get(ref)


def staging_registry() -> FakeRegistry:
    reg = FakeRegistry()
    for i, name in enumerate(PUBLISHED):
        target = STAGING["target"][name]
        for tag in target["tags"]:
            reg.tags[tag] = index(f"sha256:{i:064x}", *target["platforms"])
    return reg


def passed_candidate() -> dict:
    doc = bakeplan.build_candidate(STAGING, version="v1.2.3", sha=SHA, inspect=staging_registry(), now="t")
    doc["tests"] = {"status": "passed"}
    return doc


# --- helpers -----------------------------------------------------------------


def test_published_targets_skip_dependency_only_targets():
    assert sorted(bakeplan.published_targets(STAGING)) == PUBLISHED


@pytest.mark.parametrize(
    "ref,expected",
    [
        ("ghcr.io/a/b:v1", ("ghcr.io/a/b", "v1")),
        ("localhost:5000/a/b:v1-staging", ("localhost:5000/a/b", "v1-staging")),
    ],
)
def test_split_ref(ref, expected):
    assert bakeplan.split_ref(ref) == expected


def test_split_ref_rejects_untagged_ref_with_registry_port():
    with pytest.raises(bakeplan.PlanError):
        bakeplan.split_ref("localhost:5000/a/b")


def test_manifest_platforms_ignore_attestations_and_normalize_arm64_v8():
    m = index("sha256:1", "linux/amd64", "linux/arm64/v8", "linux/arm/v7")
    assert bakeplan.manifest_platforms(m) == ["linux/amd64", "linux/arm/v7", "linux/arm64"]


@pytest.mark.parametrize("version", ["v1.2.3", "edge", "abc1234", "v0.9.0-rc.1"])
def test_check_version_accepts_tags(version):
    assert bakeplan.check_version(version) == version


@pytest.mark.parametrize("version", ["", "-x", "a b", "v1;rm", "x" * 129])
def test_check_version_rejects_bad_tags(version):
    with pytest.raises(bakeplan.PlanError):
        bakeplan.check_version(version)


def test_split_names_rejects_option_injection():
    with pytest.raises(bakeplan.PlanError):
        bakeplan.split_names("coder,--set=*.output=x")


# --- candidate ---------------------------------------------------------------


def test_candidate_records_digest_per_published_target():
    doc = bakeplan.build_candidate(STAGING, version="v1.2.3", sha=SHA, inspect=staging_registry(), now="t")
    assert sorted(doc["images"]) == PUBLISHED
    base = doc["images"]["coder-base"]
    assert base["repo"] == "ghcr.io/idekube-project/idekube-container-coder-base"
    assert base["candidate_tags"] == ["ghcr.io/idekube-project/idekube-container-coder-base:v1.2.3-staging"]
    assert base["platforms"] == ["linux/amd64", "linux/arm64"]
    assert doc["tests"] == {"status": "pending"}
    assert doc["sha"] == SHA and doc["version"] == "v1.2.3"


def test_candidate_fails_when_a_tag_is_missing():
    reg = staging_registry()
    del reg.tags["ghcr.io/idekube-project/idekube-container-coder:conda-v1.2.3-staging"]
    with pytest.raises(bakeplan.PlanError, match="does not exist"):
        bakeplan.build_candidate(STAGING, version="v1.2.3", sha=SHA, inspect=reg)


def test_candidate_fails_on_platform_mismatch():
    reg = staging_registry()
    reg.tags["ghcr.io/idekube-project/idekube-container-coder-base:v1.2.3-staging"] = index("sha256:9", "linux/amd64")
    with pytest.raises(bakeplan.PlanError, match="platforms"):
        bakeplan.build_candidate(STAGING, version="v1.2.3", sha=SHA, inspect=reg)


def test_candidate_requires_full_sha():
    with pytest.raises(bakeplan.PlanError, match="commit id"):
        bakeplan.build_candidate(STAGING, version="v1.2.3", sha="abc1234", inspect=staging_registry())


# --- promote -----------------------------------------------------------------


def plan(candidate, registry, **kw):
    opts = dict(version="v1.2.3", expect_sha=SHA, selected=sorted(candidate["images"]), force=False)
    opts.update(kw)
    return bakeplan.plan_promotion(candidate, RELEASE, inspect=registry, **opts)


def test_promotion_creates_release_tags_from_digests():
    cand = passed_candidate()
    actions, problems = plan(cand, staging_registry())
    assert problems == []
    by_target = {a["target"]: a for a in actions}
    base = by_target["coder-base"]
    assert base["source"] == f"ghcr.io/idekube-project/idekube-container-coder-base@{cand['images']['coder-base']['digest']}"
    assert base["create"] == ["ghcr.io/idekube-project/idekube-container-coder-base:v1.2.3"]
    assert by_target["agent-openclaw-ascend"]["create"] == [
        "ghcr.io/idekube-project/idekube-container-agent:openclaw-v1.2.3-ascend"
    ]


def test_promotion_is_idempotent():
    cand = passed_candidate()
    reg = staging_registry()
    for name, img in cand["images"].items():
        for tag in RELEASE["target"][name]["tags"]:
            reg.tags[tag] = {"digest": img["digest"], "manifests": []}
    actions, problems = plan(cand, reg)
    assert problems == []
    assert all(not a["create"] and a["keep"] for a in actions)


@pytest.mark.parametrize("status", ["pending", "failed", None])
def test_promotion_requires_passed_tests(status):
    cand = passed_candidate()
    cand["tests"] = {"status": status} if status else {}
    _, problems = plan(cand, staging_registry())
    assert any("tests" in p for p in problems)


def test_promotion_checks_version_and_sha():
    cand = passed_candidate()
    _, problems = plan(cand, staging_registry(), version="v9.9.9", expect_sha="b" * 40)
    assert any("not 'v9.9.9'" in p for p in problems)
    assert any("tag points to" in p for p in problems)


def test_promotion_refuses_moved_candidate_tag():
    cand = passed_candidate()
    reg = staging_registry()
    reg.tags["ghcr.io/idekube-project/idekube-container-coder-base:v1.2.3-staging"] = {"digest": "sha256:moved"}
    _, problems = plan(cand, reg)
    assert any("moved to sha256:moved" in p for p in problems)


def test_promotion_refuses_overwrite_unless_forced():
    cand = passed_candidate()
    reg = staging_registry()
    reg.tags["ghcr.io/idekube-project/idekube-container-coder-base:v1.2.3"] = {"digest": "sha256:old"}
    actions, problems = plan(cand, reg)
    assert any("refusing to overwrite" in p for p in problems)
    actions, problems = plan(cand, reg, force=True)
    assert problems == []
    assert "ghcr.io/idekube-project/idekube-container-coder-base:v1.2.3" in {
        t for a in actions for t in a["create"]
    }


def test_promotion_reports_targets_missing_from_candidate():
    cand = passed_candidate()
    del cand["images"]["coder-conda"]
    _, problems = plan(cand, staging_registry(), selected=["coder-base", "coder-conda"])
    assert any("coder-conda: not in the candidate" in p for p in problems)


def test_promotion_rejects_release_tag_in_another_repo():
    cand = passed_candidate()
    release = copy.deepcopy(RELEASE)
    release["target"]["coder-base"]["tags"] = ["ghcr.io/evil/repo:v1.2.3"]
    _, problems = bakeplan.plan_promotion(
        cand, release, version="v1.2.3", expect_sha=SHA, selected=["coder-base"], force=False,
        inspect=staging_registry(),
    )
    assert any("is not in" in p for p in problems)
