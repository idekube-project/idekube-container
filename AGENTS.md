# AGENTS.md

This file provides guidance to Codex (codex.com/cli) and other Claude-Code-compatible agents when working with code in this repository. It mirrors `CLAUDE.md` — keep both in sync when editing one.

## Project Overview

IDEKUBE is a meta-repository for IDE containers running in Kubernetes. It provides four container flavors (featured, coder, jupyter, agent) used in robotics, ML, simulation, and education at SPEIT (Shanghai Jiao Tong University).

The build system is **centralized**: a single `docker-bake.hcl` at the meta-repo root drives every image. Image submodules under `images/` are stand-alone source trees; bake supplies shared assets (artifacts, healthcheck Go source, frontend Vue source) via BuildKit named contexts so that each Dockerfile only references paths inside its own image repo.

## Repository Layout

- **`docker-bake.hcl`** — Source-of-truth bake configuration: all targets, groups, the dependency DAG (via `target:` named contexts), and per-target build args. Replaces the old `docker-builder/build.py` Python orchestrator.
- **`docker-bake.staging.hcl`** — Override file. Sets `STAGING_POSTFIX="-staging"` and `VERSION="edge"` (overridable via env). Layered after the main file with `-f`.
- **`docker-bake.production.hcl`** — Override file for production releases. Adds GHA build cache.
- **`Makefile`** — Thin wrappers around `docker buildx bake` plus the test-suite entry points.
- **`scripts/tag-stable.sh`** — Post-publish helper that creates stable aliases via `docker buildx imagetools create`.
- **`tests/`** — pytest + Playwright test suite (parametrized per branch) for end-to-end verification.
- **`.github/workflows/publish.yml`** — Staging workflow for PRs, `main` branch pushes, and manual dispatch.
- **`.github/workflows/publish-production.yml`** — Production workflow for GitHub releases and manual dispatch. Uses `docker/bake-action@v7` with a `[universal, ascend]` job matrix.
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

# Multi-arch production + push (release tags)
make push-production GROUP=universal
make push-production GROUP=ascend

# After production push: alias <variant>-<version> as <variant>-stable
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
| `ghcr.io/idekube-project/idekube-container-jupyter` | `speit-ai`, `speit-ascendai` |
| `ghcr.io/idekube-project/idekube-container-agent-base` | `base` |
| `ghcr.io/idekube-project/idekube-container-agent` | `openclaw`, `hermes` |

Tag templates: base repos use `<VERSION>[-ascend][-staging]`; application repos use `<variant>-<VERSION>[-ascend][-staging]`; QEMU tags append `-qemu`. Examples:

- `idekube-container-featured-base:v1.0.0`
- `idekube-container-featured-base:v1.0.0-ascend`
- `idekube-container-featured-base:v1.0.0-qemu`
- `idekube-container-featured:speit-edge-staging`
- `idekube-container-featured-base:stable` (alias added post-push)

## CI/CD

Two workflows under `.github/workflows/`:

- **Triggers**: `publish.yml` runs staging builds for PRs, `main` branch pushes, and manual dispatch; `publish-production.yml` runs production builds for GitHub releases and manual dispatch.
- **Matrix**: `lineup: [universal, ascend]` runs in parallel.
- **Auth**: `GITHUB_TOKEN` → GHCR.
- **Action**: `docker/bake-action@v7` with `targets: <lineup>`, `files: docker-bake.hcl,<override>`, `push: true`. Bake's BuildKit solver schedules dependency targets first within a lineup.
- **Stable retag**: production runs `scripts/tag-stable.sh` for each `*-base` branch after push.

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
- `IDEKUBE_ACCESS_TOKEN` — Nginx-level web auth token (excludes `/ssh`)

## What's Gone

These were part of the previous decentralized layout and have been removed:

- `docker-builder/` submodule + `build.py` (replaced by `docker-bake.hcl`)
- Per-image-repo `Makefile`, `config.json`, `.dockerargs.{base,ascend}`, `CLAUDE.md`, `README.md`
- Per-image-repo `.github/workflows/publish.yml` (8 of them) — replaced by central meta-repo workflows
- Per-image-repo `third_party/` symlink farms (replaced by named contexts)
- `qemu-builder/` submodule (folded into meta-repo as plain content)
