#!/usr/bin/env python3
"""bakeplan.py: CI plans derived from `docker buildx bake --print`.

docker-bake.hcl is the only place that names images. Everything the
pipelines need about targets, tags and repos is read back from bake, so the
workflows never re-implement the naming scheme.

Subcommands:
  affected     Targets a change touches (PR CI build/test matrix).
  matrix       Build jobs: one per flavor, lineup and platform (native runners).
  override     bake override for one build job (platform, outputs, cache).
  digests      Per-platform digests a build job pushed (from bake metadata).
  merge        Assemble multi-platform manifests and write candidate.json.
  candidate    Record the digests a staging build pushed (candidate.json).
  test-matrix  Test jobs for a candidate (one per image and platform).
  set-tests    Record the test outcome in candidate.json.
  promote      Retag a tested candidate's digests with the release tags.

A candidate document (schema 1) looks like:

  {
    "schema": 1,
    "version": "v0.9.0",
    "sha": "<commit the images were built from>",
    "created": "<UTC ISO 8601>",
    "source": "<workflow run URL>",
    "tests": {"status": "pending" | "passed" | "failed", ...},
    "images": {
      "<bake target>": {
        "branch": "coder/base",
        "lineup": "universal",
        "repo": "ghcr.io/idekube-project/idekube-container-coder-base",
        "digest": "sha256:...",
        "candidate_tags": ["...:v0.9.0-staging"],
        "platforms": ["linux/amd64", "linux/arm64"]
      }
    }
  }

Release tags are never stored: promote recomputes them from docker-bake.hcl
(without the staging override), joined to the candidate by target name.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]

BAKE_FILE = "docker-bake.hcl"
STAGING_FILE = "docker-bake.staging.hcl"
SKIP_BASE_FILE = "docker-bake.skip-base.hcl"
STAGING_POSTFIX = "-staging"

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class PlanError(Exception):
    """A problem with the inputs or the registry state; reported, not traced."""


# ---------------------------------------------------------------------------
# bake
# ---------------------------------------------------------------------------


def bake_files(*, staging: bool, skip_base: bool = False) -> list[str]:
    files = [BAKE_FILE]
    if staging:
        files.append(STAGING_FILE)
    if skip_base:
        files.append(SKIP_BASE_FILE)
    return files


def bake_print(
    names: list[str],
    *,
    version: str,
    staging: bool,
    skip_base: bool = False,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Run `docker buildx bake --print` with VERSION and STAGING_POSTFIX pinned.

    Both are always set explicitly: an inherited STAGING_POSTFIX from the
    caller's environment must never turn release tags into staging tags.
    """
    for name in names:
        if not NAME_RE.match(name):
            raise PlanError(f"invalid bake target/group name {name!r}")
    check_version(version)
    run_env = dict(os.environ)
    run_env.update(env or {})
    run_env["VERSION"] = version
    run_env["STAGING_POSTFIX"] = STAGING_POSTFIX if staging else ""
    cmd = ["docker", "buildx", "bake", "--print"]
    for f in bake_files(staging=staging, skip_base=skip_base):
        cmd += ["-f", f]
    cmd += names
    result = subprocess.run(cmd, cwd=ROOT, env=run_env, capture_output=True, text=True)
    if result.returncode != 0:
        raise PlanError(f"bake --print failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def published_targets(plan: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Targets bake will export. Dependency-only targets get a cacheonly output."""
    out = {}
    for name, target in plan.get("target", {}).items():
        outputs = target.get("output") or []
        if any(isinstance(o, dict) and o.get("type") == "cacheonly" for o in outputs):
            continue
        out[name] = target
    return out


def target_branch(target: dict[str, Any]) -> str:
    """Test-suite branch of a bake target: images/featured + docker/speit/Dockerfile -> featured/speit."""
    context = target.get("context") or ""
    dockerfile = target.get("dockerfile") or ""
    parts = Path(dockerfile).parts
    if not context.startswith("images/") or len(parts) < 3 or parts[0] != "docker":
        raise PlanError(f"cannot derive a branch from context={context!r} dockerfile={dockerfile!r}")
    flavor = Path(context).name.removesuffix("-base")
    return f"{flavor}/{parts[1]}"


def target_lineup(name: str) -> str:
    return "ascend" if name.endswith("-ascend") else "universal"


def base_dependencies(plan: dict[str, Any]) -> dict[str, list[str]]:
    """target -> targets it builds FROM (bake `target:` contexts)."""
    deps = {}
    for name, target in plan.get("target", {}).items():
        deps[name] = sorted(
            v.removeprefix("target:")
            for v in (target.get("contexts") or {}).values()
            if isinstance(v, str) and v.startswith("target:")
        )
    return deps


def check_version(version: str) -> str:
    if not TAG_RE.match(version):
        raise PlanError(f"version {version!r} is not a valid image tag")
    return version


def split_ref(ref: str) -> tuple[str, str]:
    """'ghcr.io/a/b:tag' -> ('ghcr.io/a/b', 'tag'). A registry port is not a tag."""
    slash = ref.rfind("/")
    colon = ref.rfind(":")
    if colon <= slash:
        raise PlanError(f"image reference {ref!r} has no tag")
    return ref[:colon], ref[colon + 1 :]


# ---------------------------------------------------------------------------
# registry
# ---------------------------------------------------------------------------


def imagetools_manifest(ref: str) -> dict[str, Any] | None:
    """The top-level manifest of `ref`, or None when the tag does not exist."""
    result = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{json .Manifest}}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        if "not found" in result.stderr:
            return None
        raise PlanError(f"cannot inspect {ref}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def manifest_platforms(manifest: dict[str, Any]) -> list[str]:
    """Image platforms of an index, ignoring attestation manifests."""
    platforms = []
    for entry in manifest.get("manifests", []):
        p = entry.get("platform") or {}
        if p.get("os") in (None, "unknown"):
            continue
        name = f"{p['os']}/{p['architecture']}"
        # arm64/v8 is the default arm64 variant (containerd normalizes the two).
        if p.get("variant") and not (p["architecture"] == "arm64" and p["variant"] == "v8"):
            name += f"/{p['variant']}"
        platforms.append(name)
    return sorted(platforms)


# ---------------------------------------------------------------------------
# candidate
# ---------------------------------------------------------------------------


def build_candidate(
    plan: dict[str, Any],
    *,
    version: str,
    sha: str,
    inspect=imagetools_manifest,
    now: str | None = None,
) -> dict[str, Any]:
    """Resolve the digest behind every candidate tag of the published targets."""
    if not SHA_RE.match(sha):
        raise PlanError(f"sha {sha!r} is not a full commit id")
    images: dict[str, Any] = {}
    for name, target in sorted(published_targets(plan).items()):
        tags = target.get("tags") or []
        if not tags:
            raise PlanError(f"target {name} has no tags")
        repo = split_ref(tags[0])[0]
        manifest = inspect(tags[0])
        if manifest is None:
            raise PlanError(f"{name}: candidate tag {tags[0]} does not exist")
        digest = manifest["digest"]
        for tag in tags[1:]:
            other = inspect(tag)
            if other is None or other["digest"] != digest:
                raise PlanError(f"{name}: {tag} does not point to {digest}")
        platforms = manifest_platforms(manifest)
        expected = sorted(target.get("platforms") or [])
        if expected and platforms != expected:
            raise PlanError(f"{name}: {tags[0]} has platforms {platforms}, bake expects {expected}")
        images[name] = {
            "branch": target_branch(target),
            "lineup": target_lineup(name),
            "repo": repo,
            "digest": digest,
            "candidate_tags": tags,
            "platforms": platforms,
        }
    if not images:
        raise PlanError("no published targets in the bake plan")
    return {
        "schema": 1,
        "version": version,
        "sha": sha,
        "created": now or _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": os.environ.get("CANDIDATE_SOURCE", ""),
        "tests": {"status": "pending"},
        "images": images,
    }


# ---------------------------------------------------------------------------
# distributed builds
# ---------------------------------------------------------------------------

# Native runners per platform: no QEMU emulation anywhere.
RUNNERS = {"linux/amd64": "ubuntu-24.04", "linux/arm64": "ubuntu-24.04-arm"}
DIGEST_OUTPUT = "type=image,push-by-digest=true,name-canonical=true,push=true"


def build_matrix(plan: dict[str, Any]) -> list[dict[str, str]]:
    """One build job per (flavor, lineup, platform).

    A flavor's base and derived images share a job, so `target:` contexts
    are resolved inside one bake invocation and never cross jobs.
    """
    groups: dict[tuple[str, str, str], list[str]] = {}
    for name, target in published_targets(plan).items():
        flavor = target_branch(target).split("/")[0]
        for platform in target.get("platforms") or []:
            if platform not in RUNNERS:
                raise PlanError(f"{name}: no native runner for {platform}")
            groups.setdefault((flavor, target_lineup(name), platform), []).append(name)
    jobs = []
    for (flavor, lineup, platform), names in sorted(groups.items()):
        arch = platform.split("/")[1]
        jobs.append({
            "id": f"{flavor}-{lineup}-{arch}",
            "platform": platform,
            "runner": RUNNERS[platform],
            "targets": ",".join(sorted(names)),
        })
    return jobs


def bake_override(plan: dict[str, Any], *, platform: str, output: str, cache: str) -> dict[str, Any]:
    """bake JSON override for one build job.

    Every target (dependency-only ones too) builds for `platform` only.
    output "digest": published targets push by digest. BuildKit refuses to
    push a tagged ref by digest and buildx turns tags into the exporter
    name, so their tags become the bare repository. output "load": load
    into the local docker engine. cache "readwrite" | "read" | "none":
    registry cache at <repo>:buildcache-<target>-<arch>; bases export all
    stages (mode=max), images built FROM another target only their own.
    A failed cache export never fails the build (ignore-error): BuildKit
    can lose the registry session while copying lazily pulled base layers
    into the cache ("no active session ... context deadline exceeded").
    """
    if platform not in RUNNERS:
        raise PlanError(f"unsupported platform {platform!r}")
    if output not in ("digest", "load", "none") or cache not in ("readwrite", "read", "none"):
        raise PlanError(f"bad output/cache mode {output!r}/{cache!r}")
    arch = platform.split("/")[1]
    published = published_targets(plan)
    deps = base_dependencies(plan)
    targets: dict[str, Any] = {}
    for name, target in plan.get("target", {}).items():
        entry: dict[str, Any] = {"platforms": [platform]}
        tags = target.get("tags") or []
        repo = split_ref(tags[0])[0] if tags else None
        if repo and cache != "none":
            ref = f"{repo}:buildcache-{name}-{arch}"
            entry["cache-from"] = [f"type=registry,ref={ref}"]
            if cache == "readwrite":
                mode = "min" if deps.get(name) else "max"
                entry["cache-to"] = [
                    f"type=registry,ref={ref},mode={mode},image-manifest=true,oci-mediatypes=true,ignore-error=true"
                ]
        if name in published and output == "digest":
            if not repo:
                raise PlanError(f"{name} has no tags to derive its repository from")
            entry["tags"] = [repo]
            entry["output"] = [DIGEST_OUTPUT]
        elif name in published and output == "load":
            entry["output"] = ["type=docker"]
        targets[name] = entry
    return {"target": targets}


def job_digests(plan: dict[str, Any], metadata: dict[str, Any], *, platform: str) -> dict[str, Any]:
    """target -> {repo, platform, digest} for what one build job pushed."""
    out = {}
    for name, target in published_targets(plan).items():
        digest = (metadata.get(name) or {}).get("containerimage.digest")
        if not digest:
            raise PlanError(f"{name}: no containerimage.digest in the bake metadata")
        out[name] = {"repo": split_ref(target["tags"][0])[0], "platform": platform, "digest": digest}
    return out


def merge_sources(plan: dict[str, Any], digests: list[dict[str, Any]]) -> dict[str, list[str]]:
    """target -> per-platform `repo@digest` sources, checked against bake's platforms."""
    published = published_targets(plan)
    collected: dict[str, dict[str, str]] = {}
    for job in digests:
        for name, entry in job.items():
            if name not in published:
                raise PlanError(f"{name}: built but not a published target of this plan")
            repo = split_ref(published[name]["tags"][0])[0]
            if entry["repo"] != repo:
                raise PlanError(f"{name}: pushed to {entry['repo']}, expected {repo}")
            platforms = collected.setdefault(name, {})
            if entry["platform"] in platforms:
                raise PlanError(f"{name}: two digests for {entry['platform']}")
            platforms[entry["platform"]] = f"{repo}@{entry['digest']}"
    sources = {}
    for name, target in sorted(published.items()):
        got = sorted(collected.get(name, {}))
        expected = sorted(target.get("platforms") or [])
        if got != expected:
            raise PlanError(f"{name}: built for {got or 'nothing'}, bake expects {expected}")
        sources[name] = [collected[name][p] for p in expected]
    return sources


# ---------------------------------------------------------------------------
# affected (PR CI)
# ---------------------------------------------------------------------------

# Paths every image is built from (or that decide what the tests check).
GLOBAL_PATHS = ("artifacts", "healthcheck", "frontend", "docker-bake.hcl", "tests")
# CI plumbing: a change here proves itself on the smallest real image.
SMOKE_PATHS = (
    ".github/workflows/ci.yml",
    ".github/actions/run-tests",
    ".github/actions/setup-docker-buildx",
    ".github/actions/free-disk-space",
    "scripts/ci/bakeplan.py",
)
SMOKE_TARGETS = ("coder-base",)


def _under(path: str, prefix: str) -> bool:
    # Matches the directory itself (also how a pre-monorepo submodule bump
    # appeared: images/agent) and anything below it.
    return path == prefix or path.startswith(prefix + "/")


def affected_targets(plan: dict[str, Any], changed: list[str]) -> list[str]:
    """Published targets of `plan` whose image a change to `changed` can alter.

    A target is touched by files in its bake context, except other variants'
    docker/<variant>/ directories; dependents of a touched target are touched
    too. GLOBAL_PATHS touch everything.
    """
    targets = plan.get("target", {})
    published = published_targets(plan)
    if any(_under(path, g) for path in changed for g in GLOBAL_PATHS):
        return sorted(published)

    touched = set()
    for name, target in targets.items():
        context = target.get("context") or ""
        variant_dir = str(Path(context) / Path(target.get("dockerfile") or "").parent)
        for path in changed:
            if not _under(path, context):
                continue
            if _under(path, f"{context}/docker") and not _under(path, variant_dir):
                continue  # another variant's Dockerfile directory
            touched.add(name)

    deps = base_dependencies(plan)
    grew = True
    while grew:
        grew = False
        for name, bases in deps.items():
            if name not in touched and touched.intersection(bases):
                touched.add(name)
                grew = True
    # Smoke targets are added after propagation: CI plumbing needs one real
    # build and test, not the smoke target's dependents.
    if any(_under(path, s) for path in changed for s in SMOKE_PATHS):
        touched.update(t for t in SMOKE_TARGETS if t in targets)
    return sorted(touched & set(published))


def test_matrix(candidate: dict[str, Any]) -> list[dict[str, Any]]:
    """One test job per candidate image and platform.

    universal/amd64 legs gate the release; arm64 and ascend legs run on
    native arm64 runners and only report until they have proven stable.
    """
    legs = []
    for name, image in sorted(candidate.get("images", {}).items()):
        for platform in image["platforms"]:
            arch = platform.split("/")[1]
            legs.append({
                "target": name,
                "branch": image["branch"],
                "lineup": image["lineup"],
                "arch": arch,
                "runner": "ubuntu-24.04-arm" if arch == "arm64" else "ubuntu-24.04",
                "blocking": image["lineup"] == "universal" and arch == "amd64",
            })
    return legs


# ---------------------------------------------------------------------------
# promote
# ---------------------------------------------------------------------------


def plan_promotion(
    candidate: dict[str, Any],
    release_plan: dict[str, Any],
    *,
    version: str,
    expect_sha: str | None,
    selected: list[str],
    force: bool,
    inspect=imagetools_manifest,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Decide what to retag. Returns (actions, problems); nothing is pushed here.

    Each action is {"target", "source", "create": [tags], "keep": [tags]}.
    Problems block a real promotion (a dry run only reports them).
    """
    problems: list[str] = []
    if candidate.get("schema") != 1:
        problems.append(f"unsupported candidate schema {candidate.get('schema')!r}")
    if candidate.get("version") != version:
        problems.append(f"candidate is for {candidate.get('version')!r}, not {version!r}")
    if expect_sha and candidate.get("sha") != expect_sha:
        problems.append(f"candidate was built from {candidate.get('sha')}, the tag points to {expect_sha}")
    status = (candidate.get("tests") or {}).get("status")
    if status != "passed":
        problems.append(f"candidate tests are {status!r}, not 'passed'")

    release_targets = published_targets(release_plan)
    actions = []
    for name in selected:
        image = candidate["images"].get(name)
        if image is None:
            problems.append(f"{name}: not in the candidate")
            continue
        target = release_targets.get(name)
        if target is None:
            problems.append(f"{name}: not a published target of docker-bake.hcl")
            continue
        repo, digest = image["repo"], image["digest"]

        # The staging tag must still be the tested image: a later staging run
        # for the same version would have moved it.
        for tag in image["candidate_tags"]:
            current = inspect(tag)
            if current is None:
                problems.append(f"{name}: candidate tag {tag} no longer exists")
            elif current["digest"] != digest:
                problems.append(f"{name}: {tag} moved to {current['digest']} since it was tested ({digest})")

        create, keep = [], []
        for tag in target.get("tags") or []:
            if split_ref(tag)[0] != repo:
                problems.append(f"{name}: release tag {tag} is not in {repo}")
                continue
            current = inspect(tag)
            if current is None:
                create.append(tag)
            elif current["digest"] == digest:
                keep.append(tag)
            elif force:
                create.append(tag)
            else:
                problems.append(
                    f"{name}: {tag} already exists with {current['digest']}; refusing to overwrite (use force)"
                )
        actions.append({"target": name, "source": f"{repo}@{digest}", "create": create, "keep": keep})
    return actions, problems


def run_promotion(actions: list[dict[str, Any]], *, dry_run: bool) -> None:
    for action in actions:
        for tag in action["keep"]:
            print(f"= {tag} already points to {action['source']}")
        if not action["create"]:
            continue
        cmd = ["docker", "buildx", "imagetools", "create"]
        if dry_run:
            cmd.append("--dry-run")
        for tag in action["create"]:
            cmd += ["-t", tag]
        cmd.append(action["source"])
        verb = "would tag" if dry_run else "tag"
        for tag in action["create"]:
            print(f"+ {verb} {tag} <- {action['source']}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise PlanError(f"imagetools create failed for {action['target']}: {result.stderr.strip()}")


def write_summary(lines: list[str]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def split_names(value: str) -> list[str]:
    names = [n for n in (value or "").split(",") if n]
    for name in names:
        if not NAME_RE.match(name):
            raise PlanError(f"invalid bake target/group name {name!r}")
    return names


def github_output(**values: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    lines = [f"{k}={v}" for k, v in values.items()]
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))


def cmd_affected(args: argparse.Namespace) -> None:
    plan = bake_print([args.lineup], version="ci", staging=False)
    published = published_targets(plan)
    if args.targets:
        names = sorted(set(split_names(args.targets)))
        unknown = [n for n in names if n not in published]
        if unknown:
            raise PlanError(f"not published {args.lineup} targets: {', '.join(unknown)}")
        print(f"explicit targets: {', '.join(names)}", file=sys.stderr)
    else:
        if not args.changed:
            raise PlanError("give --changed or --targets")
        changed = [line.strip() for line in Path(args.changed).read_text().splitlines() if line.strip()]
        names = affected_targets(plan, changed)
        print(f"{len(changed)} changed paths -> {len(names)} targets: {', '.join(names) or 'none'}", file=sys.stderr)
    matrix = [{"target": n, "branch": target_branch(published[n])} for n in names]
    github_output(matrix=json.dumps(matrix, separators=(",", ":")), count=str(len(matrix)))


def cmd_test_matrix(args: argparse.Namespace) -> None:
    legs = test_matrix(json.loads(Path(args.candidate).read_text()))
    github_output(matrix=json.dumps(legs, separators=(",", ":")), count=str(len(legs)))


def cmd_set_tests(args: argparse.Namespace) -> None:
    path = Path(args.candidate)
    doc = json.loads(path.read_text())
    doc["tests"] = {"status": args.status, "run": os.environ.get("CANDIDATE_SOURCE", "")}
    path.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"candidate {doc['version']}: tests {args.status}")


def _job_plan(args: argparse.Namespace) -> dict[str, Any]:
    names = split_names(args.targets)
    if not names:
        raise PlanError("--targets is empty")
    return bake_print(names, version=args.version, staging=args.staging, skip_base=args.skip_base)


def cmd_matrix(args: argparse.Namespace) -> None:
    jobs = build_matrix(_job_plan(args))
    for job in jobs:
        print(f"{job['id']:<28} {job['runner']:<18} {job['targets']}", file=sys.stderr)
    github_output(matrix=json.dumps(jobs, separators=(",", ":")), count=str(len(jobs)))


def cmd_override(args: argparse.Namespace) -> None:
    doc = bake_override(_job_plan(args), platform=args.platform, output=args.output, cache=args.cache)
    Path(args.out).write_text(json.dumps(doc, indent=2) + "\n")


def cmd_digests(args: argparse.Namespace) -> None:
    metadata = json.loads(Path(args.metadata).read_text())
    doc = job_digests(_job_plan(args), metadata, platform=args.platform)
    Path(args.out).write_text(json.dumps(doc, indent=2) + "\n")
    for name, entry in sorted(doc.items()):
        print(f"{name} {entry['platform']} {entry['digest']}")


def cmd_merge(args: argparse.Namespace) -> None:
    plan = _job_plan(args)
    digests = [json.loads(p.read_text()) for p in sorted(Path(args.digests_dir).glob("*.json"))]
    sources = merge_sources(plan, digests)
    published = published_targets(plan)
    for name, srcs in sources.items():
        cmd = ["docker", "buildx", "imagetools", "create"]
        for tag in published[name]["tags"]:
            cmd += ["-t", tag]
        result = subprocess.run(cmd + srcs, capture_output=True, text=True)
        if result.returncode != 0:
            raise PlanError(f"{name}: imagetools create failed: {result.stderr.strip()}")
        print(f"{name}: {', '.join(published[name]['tags'])} <- {len(srcs)} platform(s)")
    # Re-read what the tags now hold: checks the platform sets and records
    # the final index digests.
    doc = build_candidate(plan, version=args.version, sha=args.sha)
    Path(args.out).write_text(json.dumps(doc, indent=2) + "\n")
    print(f"candidate {args.version} @ {args.sha[:7]}: {len(doc['images'])} images -> {args.out}")


def cmd_candidate(args: argparse.Namespace) -> None:
    names = split_names(args.targets)
    if not names:
        raise PlanError("--targets is empty")
    plan = bake_print(names, version=args.version, staging=True, skip_base=args.skip_base)
    doc = build_candidate(plan, version=args.version, sha=args.sha)
    Path(args.out).write_text(json.dumps(doc, indent=2) + "\n")
    print(f"candidate {args.version} @ {args.sha[:7]}: {len(doc['images'])} images -> {args.out}")


def cmd_promote(args: argparse.Namespace) -> None:
    check_version(args.version)
    candidate = json.loads(Path(args.candidate).read_text())
    images = sorted(candidate.get("images", {}))
    if args.targets:
        # Accept groups as well as targets: expand them like bake does.
        expanded = published_targets(bake_print(split_names(args.targets), version=args.version, staging=False))
        selected = sorted(expanded)
    else:
        selected = images
    release_plan = bake_print(selected, version=args.version, staging=False) if selected else {"target": {}}
    actions, problems = plan_promotion(
        candidate,
        release_plan,
        version=args.version,
        expect_sha=args.expect_sha,
        selected=selected,
        force=args.force,
    )
    for problem in problems:
        level = "warning" if args.dry_run else "error"
        print(f"::{level}::{problem}", file=sys.stderr)
    if problems and not args.dry_run:
        raise PlanError(f"promotion of {args.version} refused ({len(problems)} problem(s))")
    run_promotion(actions, dry_run=args.dry_run)
    created = sum(len(a["create"]) for a in actions)
    kept = sum(len(a["keep"]) for a in actions)
    mode = "dry run" if args.dry_run else "promoted"
    print(f"{mode}: {len(actions)} targets, {created} tags to create, {kept} already in place")
    summary = [f"### Promotion of `{args.version}` ({mode})", "", "| target | source | new tags |", "|---|---|---|"]
    for a in actions:
        summary.append(f"| {a['target']} | `{a['source'].split('@')[1][:19]}` | {', '.join(f'`{t}`' for t in a['create']) or '—'} |")
    if problems:
        summary += ["", "**Problems:**", *[f"- {p}" for p in problems]]
    write_summary(summary)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("affected", help="targets a change touches (writes matrix/count outputs)")
    p.add_argument("--changed", help="file with one changed path per line (git diff --name-only)")
    p.add_argument("--targets", default="", help="explicit comma-separated targets instead of --changed")
    p.add_argument("--lineup", default="universal", choices=["universal", "ascend"])
    p.set_defaults(func=cmd_affected)

    def job_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--targets", required=True, help="comma-separated bake targets/groups")
        p.add_argument("--version", required=True)
        p.add_argument("--staging", action="store_true", help="layer docker-bake.staging.hcl (-staging tags)")
        p.add_argument("--skip-base", action="store_true", help="layer docker-bake.skip-base.hcl")

    p = sub.add_parser("matrix", help="build jobs per flavor, lineup and platform (writes matrix/count outputs)")
    job_args(p)
    p.set_defaults(func=cmd_matrix)

    p = sub.add_parser("override", help="bake override file for one build job")
    job_args(p)
    p.add_argument("--platform", required=True, choices=sorted(RUNNERS))
    p.add_argument("--output", required=True, choices=["digest", "load", "none"])
    p.add_argument("--cache", default="read", choices=["readwrite", "read", "none"])
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_override)

    p = sub.add_parser("digests", help="digests one build job pushed, from bake --metadata-file")
    job_args(p)
    p.add_argument("--platform", required=True, choices=sorted(RUNNERS))
    p.add_argument("--metadata", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_digests)

    p = sub.add_parser("merge", help="create multi-platform manifests from the jobs' digests, write candidate.json")
    job_args(p)
    p.add_argument("--digests-dir", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--out", default="candidate.json")
    p.set_defaults(func=cmd_merge)

    p = sub.add_parser("test-matrix", help="test jobs for a candidate (writes matrix/count outputs)")
    p.add_argument("--candidate", required=True)
    p.set_defaults(func=cmd_test_matrix)

    p = sub.add_parser("set-tests", help="record the test outcome in candidate.json")
    p.add_argument("--candidate", required=True)
    p.add_argument("--status", required=True, choices=["passed", "failed"])
    p.set_defaults(func=cmd_set_tests)

    p = sub.add_parser("candidate", help="record the digests of a staging build")
    p.add_argument("--version", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--targets", required=True, help="comma-separated bake targets/groups that were built")
    p.add_argument("--skip-base", action="store_true", help="the build layered docker-bake.skip-base.hcl")
    p.add_argument("--out", default="candidate.json")
    p.set_defaults(func=cmd_candidate)

    p = sub.add_parser("promote", help="retag a tested candidate with the release tags")
    p.add_argument("--candidate", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--expect-sha", help="commit the release tag points to")
    p.add_argument("--targets", default="", help="only these targets/groups (default: the whole candidate)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--force", action="store_true", help="overwrite release tags that point elsewhere")
    p.set_defaults(func=cmd_promote)

    args = parser.parse_args(argv)
    try:
        args.func(args)
    except PlanError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
