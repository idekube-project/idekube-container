# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

IDEKUBE is a meta-repository for IDE containers running in Kubernetes. It provides four container flavors (featured, coder, jupyter, agent) used in robotics, ML, simulation, and education at SPEIT (Shanghai Jiao Tong University). All sub-projects are git submodules with independent versioning.

## Repository Layout

- **`docker-builder/`** — Python build orchestrator (`build.py`) that scans `docker/*/images.json`, resolves the dependency DAG, and builds images in topological order. Also hosts the reusable GitHub Actions workflow (`publish-reusable.yml`) used by all image repos.
- **`artifacts/`** — Shared install scripts (`install-scripts/`) and rootfs overlays (`rootfs/`) used by all image Dockerfiles via `RUN --mount=type=bind`
- **`frontend/`** — Vue 3 + TypeScript + Vite landing page; outputs `dist/` served by nginx
- **`healthcheck/`** — Go HTTP server (Gin + Gorilla WebSocket) on `:9999` that probes container services and returns JSON health status
- **`images/<flavor>-base/`** — Base image projects (featured-base, coder-base, jupyter-base, agent-base)
- **`images/<flavor>/`** — Derived image projects that `FROM` their base's `stable` tag

## Build Commands

All image projects follow the same Makefile pattern:

```bash
cd images/<any-image-project>
make prepare        # Init submodules + create symlinks to artifacts/healthcheck/frontend
make build          # Build single image (default branch)
make build BRANCH=featured/speit   # Build a specific variant
make build-all      # Build all variants in DAG order
make publishx-all   # Multi-arch build + push to registry
make tag-stable     # Retag current as stable after verification
make discover       # Show discovered images and their dependencies
```

Frontend:

```bash
cd frontend
npm ci && npm run build
```

Healthcheck (compiled as multi-stage build inside Dockerfiles):

```bash
cd healthcheck
go build ./...
go test ./...
```

## Image Project Structure

Each image project under `images/` follows a consistent layout:

- **`config.json`** — Registry (`ghcr.io`), author (`idekube-project`), name, architectures, lineup definitions
- **`.dockerargs.<lineup>`** — Build-time variables (BASE_IMAGE, tool versions); env vars override these
- **`Makefile`** — Delegates to `build.py` from docker-builder submodule
- **`docker/<variant>/`** — Each variant has:
  - `Dockerfile` — Multi-stage build (healthcheck builder stage → system stage)
  - `images.json` — `{"branch": "<flavor>/<variant>", "depends_on": "<parent-branch-or-null>"}`
  - `install-scripts/` — Variant-specific setup scripts
- **`artifacts/docker/<flavor>/rootfs/`** — Runtime filesystem overlay (supervisor, nginx, health.json configs)

## Container Registry

Images are published to GitHub Container Registry at `ghcr.io/idekube-project/idekube-container:<tag>` (QEMU images at `ghcr.io/idekube-project/idekube-container-qemu:<tag>`). Registry and author are configured in each image project's `config.json` and can be overridden via `REGISTRY` and `AUTHOR` environment variables.

## CI/CD

All image repos use a reusable GitHub Actions workflow hosted in `docker-builder`:

- **Reusable workflow**: `idekube-project/idekube-container-docker-builder/.github/workflows/publish-reusable.yml@main`
- **Triggers**: `v*` tag push or manual `workflow_dispatch`
- **Auth**: GHCR login via `GITHUB_TOKEN` (no extra secrets needed)
- **Matrix**: Builds both `base` and `ascend` lineups by default; can select one via dispatch input
- **Base repos** (`*-base`): Build single image, tag stable on `v*` push, set up Node.js for frontend build
- **Derived repos**: Build all variants in DAG order via `publishx-all`, optional `branch` input for single variant

## Key Architecture Concepts

- **Lineups**: A single image project can produce multiple architecture variants (e.g., `base` lineup for amd64+arm64, `ascend` lineup for arm64-only with Ascend NPU). Each lineup has its own `.dockerargs` file.
- **Symlink prepare step**: `make prepare` creates `third_party/` symlinks pointing to submodule paths (artifacts, healthcheck, frontend, qemu-builder). Dockerfiles reference these via bind mounts.
- **Stable tag contract**: Base images publish a `stable` tag. Derived images `FROM <base>:stable` by default, so base must be tagged stable before derived images can build.
- **Health config**: Each image ships `/etc/idekube/health.json` defining which services to probe. The healthcheck binary reads this at runtime.
- **Services are reverse-proxied**: All services (Coder, Jupyter, noVNC, ttyd, SSH) sit behind nginx on port 80 with path-based routing.

## Known build.py Issues

- `compute_base_image_arg()` uses `docker/<last-segment>/images.json` existence to detect internal vs external dependencies — can misidentify when multiple flavors share a variant name
- `parse_dockerargs()` does not handle quoted values or inline comments
- `detect_git_tag()` filters pre-release tags by substring match (`-rc`, `-alpha`, `-beta`), which can false-positive on branch names containing those strings
- `resolve_dag()` reports cycle detection but does not identify which images form the cycle

## Runtime Environment Variables

- `IDEKUBE_INIT_HOME` — Initialize home from `/etc/skel`
- `IDEKUBE_PREFERED_SHELL` — Path to preferred shell
- `IDEKUBE_USER_UID` — Override container user UID
- `IDEKUBE_AUTHORIZED_KEYS` — Base64-encoded SSH authorized keys
- `IDEKUBE_ACCESS_TOKEN` — Nginx-level web auth token (excludes `/ssh`)
