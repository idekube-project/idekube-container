# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

IDEKUBE is a meta-repository for IDE containers running in Kubernetes. It provides four container flavors (featured, coder, jupyter, agent) used in robotics, ML, simulation, and education at SPEIT (Shanghai Jiao Tong University).

The build system is **centralized**: a single `docker-bake.hcl` at the meta-repo root drives every image. Image submodules under `images/` are stand-alone source trees; bake supplies shared assets (artifacts, healthcheck Go source, frontend Vue source) via BuildKit named contexts so that each Dockerfile only references paths inside its own image repo.

## Repository Layout

- **`docker-bake.hcl`** — Source-of-truth bake configuration: all targets, groups, the dependency DAG (via `target:` named contexts), and per-target build args. Replaces the old `docker-builder/build.py` Python orchestrator.
- **`docker-bake.staging.hcl`** — Override file. Sets `STAGING_POSTFIX="-staging"` and `VERSION="edge"` (overridable via env). Layered after the main file with `-f`.
- **`docker-bake.production.hcl`** — Override file for *local* production builds only (overrides nothing). CI never builds production images; it promotes tested candidates.
- **`Makefile`** — Thin wrappers around `docker buildx bake` plus the test-suite entry points.
- **`scripts/tag-stable.sh`** — Post-promotion helper that creates stable aliases via `docker buildx imagetools create`.
- **`scripts/ci/bakeplan.py`** — Reads `docker buildx bake --print` so CI never re-implements image naming. `candidate` records the digests a staging build pushed (`candidate.json`); `promote` retags those digests with the release tags. Unit tests: `uv run --project tests pytest scripts/ci/tests`.
- **`scripts/ci/frontend-hash.sh`** — `FRONTEND_HASH` for builds (`git rev-parse --short HEAD:frontend`).
- **`scripts/ci-resolve-targets.sh`** — Called by both publish workflows: validates dispatch inputs (passed via `env:`, never `${{ }}`-interpolated into `run:`) and resolves the bake targets for a matrix leg.
- **`tests/`** — pytest + Playwright test suite (parametrized per branch) for end-to-end verification.
- **`.github/workflows/publish.yml`** — Staging (candidate) builds for prereleases and manual dispatch; writes `candidate.json`.
- **`.github/workflows/publish-production.yml`** — Promotes a release's tested candidate by digest on `release: released` (or dispatch). Builds nothing.
- **`artifacts/`** (submodule) — Shared install scripts and common rootfs overlay. Mounted into builds via `--build-context artifacts=...`.
- **`frontend/`** (submodule) — Vue 3 + TypeScript + Vite landing page **source**. Built inside the bake-driven Docker stage via `--build-context frontend-src=...`.
- **`healthcheck/`** (submodule) — Go HTTP health server **source**. Compiled inside the bake-driven Docker stage via `--build-context healthcheck-src=...`.
- **`qemu-builder/`** — QEMU VM build pipeline (Ansible + cloud-init). Folded into the meta-repo as plain tracked content; no longer a submodule.
- **`images/<flavor>(-base)?/`** (submodules) — One per image repo. Each is self-contained (Dockerfiles, variant install-scripts, per-flavor rootfs overlay) and only references paths inside its own tree plus named contexts.

## Build Commands

All builds go through bake at the meta-repo root.

```bash
# One-time
make prepare                          # git submodule update --init --recursive

# Local single-arch build (loads into host docker)
make bake TARGET=featured-base-universal
make bake TARGET=agent-openclaw

# Multi-arch staging (no push)
make bake-staging GROUP=universal
make bake-staging GROUP=ascend

# Multi-arch staging + push (-staging tag postfix)
make push-staging GROUP=universal

# Multi-arch production + push (release tags). Bypasses the CI candidate/test
# gate: only for recovering from a broken pipeline. Normal releases: see CI/CD.
make push-production GROUP=universal
make push-production GROUP=ascend

# Alias <variant>-<version> as <variant>-stable (CI does this on promotion)
make tag-stable BRANCH=featured/base

# Inspect the bake plan
make discover GROUP=universal
docker buildx bake --print -f docker-bake.hcl universal
```

## docker-bake.hcl Schema

Variables are env-overridable. The most-used ones:

- `REGISTRY`, `AUTHOR`, `NAME_PREFIX` — registry path components
- `VERSION` — image version (CI sets from git tag or short SHA)
- `STAGING_POSTFIX` — `""` (production) or `"-staging"` (staging override file)
- `LINEUPS` — list of `{lineup, base, postfix, platforms}` consumed by the matrix-expanded dual-lineup targets

Each branch is a target. Targets that exist in **both** the universal and ascend lineups (`featured/base`, `featured/speit-ai`, `jupyter/base`, `jupyter/speit-ai`) use a `matrix = { item = LINEUPS }` block, expanding into `<name>-universal` and `<name>-ascend`. Single-lineup targets are declared directly.

Dependency edges are expressed via `target:` named contexts:

```hcl
target "featured-speit" {
  contexts = { "base-image" = "target:featured-base-universal" }
}
```

When bake builds `featured-speit`, it builds `featured-base-universal` first and routes the result through the `base-image` named context. The Dockerfile uses `ARG BASE_IMAGE=base-image` + `FROM ${BASE_IMAGE}` so BuildKit resolves the named context automatically.

## Image-Repo Self-Containment Contract

Every image repo's Dockerfile must reference only:

1. Paths beneath `docker/<variant>/` (Dockerfile + per-variant install-scripts)
2. Paths beneath `artifacts/docker/<flavor>/rootfs/` (per-flavor rootfs overlay, lives **inside** the image repo)
3. Named build contexts: `artifacts`, `healthcheck-src`, `frontend-src`, `base-image`

Anything else is a bug. Audit with:

```bash
grep -nH 'third_party\|tools/idekube-healthcheck\|frontend/dist' images/*/docker/*/Dockerfile
# (must return nothing)
```

## Container Registry

Per-flavor GHCR repos. Each image submodule publishes to its own repo:

| Repo | Variants |
|------|----------|
| `ghcr.io/idekube-project/idekube-container-featured-base` | `base` |
| `ghcr.io/idekube-project/idekube-container-featured` | `speit`, `speit-ai`, `dind`, `kathara`, `ros2` |
| `ghcr.io/idekube-project/idekube-container-coder-base` | `base` |
| `ghcr.io/idekube-project/idekube-container-coder` | `conda` |
| `ghcr.io/idekube-project/idekube-container-jupyter-base` | `base` |
| `ghcr.io/idekube-project/idekube-container-jupyter` | `speit-ai` |
| `ghcr.io/idekube-project/idekube-container-agent-base` | `base` |
| `ghcr.io/idekube-project/idekube-container-agent` | `openclaw`, `hermes` |

Tag templates: base repos use `<VERSION>[-ascend][-staging]`; application repos use `<variant>-<VERSION>[-ascend][-staging]`; QEMU tags append `-qemu`. Examples:

- `idekube-container-featured-base:v1.0.0`
- `idekube-container-featured-base:v1.0.0-ascend`
- `idekube-container-featured-base:v1.0.0-qemu`
- `idekube-container-featured:speit-edge-staging`
- `idekube-container-featured-base:stable` (alias added post-push)

## CI/CD

Release images are built once and promoted, never rebuilt: production ships the exact digests the staging run built (and, once wired in, tested).

- **`publish.yml` (staging)** — triggered by `release: prereleased` and manual dispatch. Builds with the `-staging` tag postfix (`docker/bake-action`, `[universal, ascend]` job matrix), then a `candidate` job records every pushed digest in `candidate.json` (`scripts/ci/bakeplan.py candidate`). When a release named after the version exists, `candidate.json` is attached to it. `VERSION` is the release tag, the dispatch `version` input (which also checks that tag out), or the short SHA.
- **`publish-production.yml` (promotion)** — triggered by `release: released` (a prerelease edited into a release, or a release published directly) and manual dispatch (`version`, `targets`, `dry_run`, `force`). Downloads the release's `candidate.json`, checks it was built from the tag's commit, that its tests passed, and that every `-staging` tag still points to the recorded digest, then `imagetools create`s the release tags from those digests (`bakeplan.py promote`). Release tags that already point elsewhere are refused unless `force`; re-running is idempotent.
- **Stable aliases** — after a full promotion of the version that is `releases/latest`, `scripts/tag-stable.sh` aliases each `*-base` repo's `stable` / `stable-ascend`. Promoting an older release never moves `stable` back.
- **Auth** — `GITHUB_TOKEN` → GHCR.

### Releasing

1. `gh release create vX.Y.Z --prerelease --generate-notes` with your own gh login (releases created with a workflow's `GITHUB_TOKEN` trigger no workflows).
2. Wait for **publish-staging** to finish; the release now has `candidate.json`.
3. `gh release edit vX.Y.Z --prerelease=false --latest` → **publish-production** promotes in minutes.

If step 3 fails because `candidate.json` is missing (e.g. the release was published directly), dispatch publish-staging with `version=vX.Y.Z`, then re-run the failed promotion. Rehearse with a publish-production dispatch and `dry_run: true`.

### Bake group taxonomy

| Group name | Scope |
|---|---|
| `default` | Alias for `universal` |
| `universal`, `ascend` | One full lineup, every flavor |
| `all` | `universal` + `ascend` |
| `featured`, `coder`, `jupyter`, `agent` | Historical per-flavor convenience |
| `<branch>-all` (e.g. `agent-base-all`) | Both lineups of one matrix-expanded branch |
| `<flavor>-<lineup>` (e.g. `agent-ascend`) | One flavor × one lineup |

### Workflow dispatch UX

publish-staging accepts these `workflow_dispatch` inputs (publish-production only takes `version`, `targets`, `dry_run`, `force`):

- `version` — release tag to build a candidate for. Empty (default): current ref, versioned by short SHA.

- `lineup` — `universal`, `ascend`, or `both` (default). Used when `targets` is empty.
- `targets` — bake target or group name. Empty (default) falls back to lineup-driven behavior; non-empty overrides.
- `skip_base` — boolean (default: false). When true, layers `docker-bake.skip-base.hcl` so derived targets pull a pre-built base image from the registry instead of rebuilding it.
- `base_tag` — universal base image tag when `skip_base` is enabled (default: `stable`). Examples: `stable`, `v0.8.3`, `edge-staging`.
- `base_tag_ascend` — ascend base image tag when `skip_base` is enabled. Empty (default) falls back to `<base_tag>-ascend`. Set explicitly when the ascend tag doesn't follow that pattern (e.g. `edge-ascend-staging`).

**Routing rule**: when `targets` is non-empty, exactly **one** runner job runs — the universal leg (the default leg). The job builds whatever the `targets` value resolves to via bake's group expansion. The matrix leg label is just a runner-job slot, not a filter on what bake builds — ascend images can still be produced when the requested group (e.g. `agent-ascend`, `agent-base-all`) contains ascend targets, and they're built via qemu-emulated arm64 on the amd64 runner.

**Skip-base mode**: `docker-bake.skip-base.hcl` replaces every `target:` dependency edge with a `docker-image://` registry pull, so bake skips the base-image build entirely. Useful when only a derived target changed (e.g. `agent-openclaw`) and the base is already published. The override sets `STABLE_TAG` / `STABLE_TAG_ASCEND` bake variables from the `base_tag` / `base_tag_ascend` workflow inputs. With `targets` empty, a leg builds `<lineup>-derived` (groups defined in the override) instead of the full lineup, whose base targets would otherwise still be rebuilt and pushed. If `targets` still resolves to a `*-base*` target, the run fails instead of silently rebuilding it.

**Input validation**: `targets` must be comma-separated `[a-z0-9-]` names; `version`, release tags and base tags must match the Docker tag grammar. Actions are pinned to commit SHAs (version in a trailing comment) and kept current by `.github/dependabot.yml`.

Promotion skips the stable aliases when `targets` is set; run `scripts/tag-stable.sh` manually if you need one from a scoped release.

## Testing

```bash
make test_deps                        # one-time: uv sync + playwright install
make test BRANCH=featured/base LINEUP=universal
make test_all                         # universal lineup, parallel via pytest-xdist
make test_all_ascend                  # ascend lineup
```

`tests/helpers/images.py` resolves locally-built or pushed image refs in the new per-flavor scheme. `LINEUP_BRANCHES`, `BRANCH_REPO`, and `BRANCH_DEPENDS_ON` mirror the bake config.

## Runtime Environment Variables

- `IDEKUBE_INIT_HOME` — Initialize home from `/etc/skel`
- `IDEKUBE_PREFERED_SHELL` — Path to preferred shell
- `IDEKUBE_USER_UID` — Override container user UID
- `IDEKUBE_AUTHORIZED_KEYS` — Base64-encoded SSH authorized keys
- `IDEKUBE_ACCESS_TOKEN` — Nginx-level web auth token (excludes `/ssh`). Letters, digits, `.`, `_`, `-` only, compared case-sensitively. `/authn.sh` re-renders the nginx map from the read-only template `/etc/idekube/nginx/access_token.conf.template` on every start; an invalid token makes the container exit (fail closed), and the image ships a deny-all map
- `IDEKUBE_ROOTFS_RESET` — With `I_AM_INIT_CONTAINER`, re-seed an already initialized `/rootfs` volume (otherwise the init container skips it)

## What's Gone

These were part of the previous decentralized layout and have been removed:

- `docker-builder/` submodule + `build.py` (replaced by `docker-bake.hcl`)
- Per-image-repo `Makefile`, `config.json`, `.dockerargs.{base,ascend}`, `CLAUDE.md`, `README.md`
- Per-image-repo `.github/workflows/publish.yml` (8 of them) — replaced by central meta-repo workflows
- Per-image-repo `third_party/` symlink farms (replaced by named contexts)
- `qemu-builder/` submodule (folded into meta-repo as plain content)
