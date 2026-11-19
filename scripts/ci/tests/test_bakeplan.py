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


# --- branches, affected, test matrix -------------------------------------------

UNIVERSAL = json.loads((HERE / "fixtures" / "plan-universal.json").read_text())
ALL_UNIVERSAL = sorted(bakeplan.published_targets(UNIVERSAL))


@pytest.mark.parametrize(
    "name,branch",
    [
        ("featured-base-universal", "featured/base"),
        ("featured-speit-ai-universal", "featured/speit-ai"),
        ("coder-conda", "coder/conda"),
        ("agent-hermes", "agent/hermes"),
    ],
)
def test_target_branch(name, branch):
    assert bakeplan.target_branch(UNIVERSAL["target"][name]) == branch


def test_candidate_records_branch_and_lineup():
    doc = bakeplan.build_candidate(STAGING, version="v1.2.3", sha=SHA, inspect=staging_registry(), now="t")
    assert doc["images"]["agent-openclaw-ascend"]["branch"] == "agent/openclaw"
    assert doc["images"]["agent-openclaw-ascend"]["lineup"] == "ascend"
    assert doc["images"]["coder-conda"]["lineup"] == "universal"


@pytest.mark.parametrize(
    "changed,expected",
    [
        (["README.md", "qemu-builder/run.sh"], []),
        (["tests/conftest.py"], ALL_UNIVERSAL),
        (["artifacts"], ALL_UNIVERSAL),  # submodule bump
        (["docker-bake.hcl"], ALL_UNIVERSAL),
        (["images/agent"], ["agent-hermes", "agent-openclaw-universal"]),
        (["images/featured/docker/speit/Dockerfile"], ["featured-speit"]),
        (["images/featured/docker/dind/setup.sh"], ["featured-dind", "featured-kathara"]),
        (
            ["images/featured/artifacts/x"],
            ["featured-dind", "featured-kathara", "featured-ros2", "featured-speit", "featured-speit-ai-universal"],
        ),
        (["images/coder-base/docker/base/Dockerfile"], ["coder-base", "coder-conda"]),
        ([".github/workflows/ci.yml"], ["coder-base"]),
        (["images/agent-basement/x"], []),  # prefix match must respect path segments
    ],
)
def test_affected_targets(changed, expected):
    assert bakeplan.affected_targets(UNIVERSAL, changed) == sorted(expected)


def test_test_matrix_blocks_only_on_universal_amd64():
    doc = passed_candidate()
    legs = bakeplan.test_matrix(doc)
    blocking = {(leg["target"], leg["arch"]) for leg in legs if leg["blocking"]}
    assert blocking == {
        ("agent-openclaw-universal", "amd64"),
        ("coder-base", "amd64"),
        ("coder-conda", "amd64"),
    }
    arm = [leg for leg in legs if leg["arch"] == "arm64"]
    assert arm and all(leg["runner"] == "ubuntu-24.04-arm" for leg in arm)
    assert {leg["lineup"] for leg in legs if leg["target"] == "agent-openclaw-ascend"} == {"ascend"}


def test_set_tests_marks_candidate(tmp_path, monkeypatch):
    path = tmp_path / "candidate.json"
    path.write_text(json.dumps(passed_candidate()))
    monkeypatch.setenv("CANDIDATE_SOURCE", "https://example/run/1")
    assert bakeplan.main(["set-tests", "--candidate", str(path), "--status", "failed"]) == 0
    doc = json.loads(path.read_text())
    assert doc["tests"] == {"status": "failed", "run": "https://example/run/1"}


# --- distributed builds ----------------------------------------------------------


def test_build_matrix_one_job_per_flavor_lineup_platform():
    jobs = bakeplan.build_matrix(UNIVERSAL)
    by_id = {j["id"]: j for j in jobs}
    assert sorted(by_id) == [
        "agent-universal-amd64", "agent-universal-arm64",
        "coder-universal-amd64", "coder-universal-arm64",
        "featured-universal-amd64", "featured-universal-arm64",
        "jupyter-universal-amd64", "jupyter-universal-arm64",
    ]
    assert by_id["coder-universal-arm64"] == {
        "id": "coder-universal-arm64",
        "platform": "linux/arm64",
        "runner": "ubuntu-24.04-arm",
        "targets": "coder-base,coder-conda",
    }
    assert by_id["featured-universal-amd64"]["runner"] == "ubuntu-24.04"


def test_build_matrix_keeps_ascend_on_arm64_only():
    jobs = bakeplan.build_matrix(STAGING)
    ascend = [j for j in jobs if "ascend" in j["id"]]
    assert [j["id"] for j in ascend] == ["agent-ascend-arm64"]
    assert ascend[0]["targets"] == "agent-openclaw-ascend"


def test_override_pushes_published_targets_by_digest_to_their_repo():
    doc = bakeplan.bake_override(STAGING, platform="linux/arm64", output="digest", cache="readwrite")["target"]
    conda = doc["coder-conda"]
    assert conda["tags"] == ["ghcr.io/idekube-project/idekube-container-coder"]
    assert conda["output"] == [bakeplan.DIGEST_OUTPUT]
    assert conda["platforms"] == ["linux/arm64"]
    ref = "ghcr.io/idekube-project/idekube-container-coder:buildcache-coder-conda-arm64"
    assert conda["cache-from"] == [f"type=registry,ref={ref}"]
    # FROM another target: own layers only.
    assert conda["cache-to"] == [f"type=registry,ref={ref},mode=min,image-manifest=true,oci-mediatypes=true"]
    assert "mode=max" in doc["coder-base"]["cache-to"][0]


def test_override_leaves_dependency_only_targets_cacheonly_but_single_platform():
    doc = bakeplan.bake_override(STAGING, platform="linux/amd64", output="digest", cache="read")["target"]
    dep = doc["agent-base-universal"]
    assert dep["platforms"] == ["linux/amd64"]  # never an emulated second platform
    assert "output" not in dep and "tags" not in dep
    assert "cache-to" not in dep and dep["cache-from"]


def test_override_load_mode_keeps_tags():
    doc = bakeplan.bake_override(STAGING, platform="linux/amd64", output="load", cache="none")["target"]
    assert doc["coder-base"] == {"platforms": ["linux/amd64"], "output": ["type=docker"]}


def test_override_rejects_emulated_platforms():
    with pytest.raises(bakeplan.PlanError):
        bakeplan.bake_override(STAGING, platform="linux/riscv64", output="digest", cache="none")


def test_job_digests_reads_bake_metadata():
    meta = {n: {"containerimage.digest": f"sha256:{i}"} for i, n in enumerate(PUBLISHED)}
    meta["buildx.build.warnings"] = []
    doc = bakeplan.job_digests(STAGING, meta, platform="linux/arm64")
    assert doc["coder-base"] == {
        "repo": "ghcr.io/idekube-project/idekube-container-coder-base",
        "platform": "linux/arm64",
        "digest": "sha256:2",
    }
    del meta["coder-conda"]
    with pytest.raises(bakeplan.PlanError, match="coder-conda"):
        bakeplan.job_digests(STAGING, meta, platform="linux/arm64")


def _jobs(platforms: dict[str, list[str]]) -> list[dict]:
    jobs = []
    for platform, names in platforms.items():
        job = {}
        for n in names:
            repo = bakeplan.split_ref(STAGING["target"][n]["tags"][0])[0]
            job[n] = {"repo": repo, "platform": platform, "digest": f"sha256:{n}-{platform[-5:]}"}
        jobs.append(job)
    return jobs


def test_merge_sources_pairs_platform_digests():
    universal = ["agent-openclaw-universal", "coder-base", "coder-conda"]
    jobs = _jobs({"linux/amd64": universal, "linux/arm64": universal + ["agent-openclaw-ascend"]})
    sources = bakeplan.merge_sources(STAGING, jobs)
    assert sources["coder-base"] == [
        "ghcr.io/idekube-project/idekube-container-coder-base@sha256:coder-base-amd64",
        "ghcr.io/idekube-project/idekube-container-coder-base@sha256:coder-base-arm64",
    ]
    assert len(sources["agent-openclaw-ascend"]) == 1


def test_merge_sources_rejects_missing_platform():
    jobs = _jobs({"linux/amd64": PUBLISHED})
    with pytest.raises(bakeplan.PlanError, match="bake expects"):
        bakeplan.merge_sources(STAGING, jobs)


def test_merge_sources_rejects_duplicates_and_wrong_repo():
    jobs = _jobs({"linux/amd64": ["coder-base"]}) * 2
    with pytest.raises(bakeplan.PlanError, match="two digests"):
        bakeplan.merge_sources(STAGING, jobs)
    jobs = _jobs({"linux/amd64": ["coder-base"]})
    jobs[0]["coder-base"]["repo"] = "ghcr.io/evil/repo"
    with pytest.raises(bakeplan.PlanError, match="expected"):
        bakeplan.merge_sources(STAGING, jobs)
