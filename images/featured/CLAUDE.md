# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Derived image project for the **featured** flavor. Builds on top of `featured/base` (stable tag). Produces variants: `speit`, `speit-ai`, `dind`, `kathara`, `ros2`. Part of the [idekube-container](https://github.com/idekube-project/idekube-container) project.

## Build Commands

```bash
make prepare                              # Init submodules
make build BRANCH=featured/speit          # Build a specific variant
make build-all                            # Build all variants in DAG order
make publishx BRANCH=featured/speit       # Multi-arch build + push single variant
make publishx-all                         # Multi-arch build + push all variants
make publishx-all LINEUP=ascend           # Build all for Ascend lineup
make discover                             # Show image DAG
```

## Project Structure

- **`config.json`** — Registry (`ghcr.io`), author (`idekube-project`), architectures, lineup definitions
- **`.dockerargs.base`** / **`.dockerargs.ascend`** — Build-time variables per lineup
- **`docker/<variant>/`** — Each variant (speit, speit-ai, dind, kathara, ros2) has:
  - `Dockerfile` — `FROM` the base stable tag, adds variant-specific packages
  - `images.json` — `{"branch": "featured/<variant>", "depends_on": "featured/base"}` (or another variant, e.g. kathara depends on dind)
  - `install-scripts/` — Variant-specific setup scripts
- **`qemu/kathara/`** — QEMU VM variant for kathara with Ansible provisioning

## Dependency Graph

```
featured/base (stable) ──> speit
                       ──> speit-ai
                       ──> dind ──> kathara
                       ──> ros2
```

## CI/CD

GitHub Actions workflow (`.github/workflows/publish.yml`) calls the reusable workflow from `idekube-project/idekube-container-docker-builder`. Triggers on `v*` tags or manual dispatch. Supports `branch` input for building a single variant. Authenticates to GHCR via `GITHUB_TOKEN`.

## Key Concepts

- **DAG-ordered builds**: `build-all` / `publishx-all` resolve dependencies and build tier-by-tier (e.g. `dind` before `kathara`). Configurable parallelism via `MAX_PARALLEL`.
- **Stable tag contract**: This repo `FROM ghcr.io/idekube-project/idekube-container:featured-base-stable`. The base image must be tagged stable before these variants can build.
- **Lineups**: `base` lineup builds for amd64+arm64. `ascend` lineup builds arm64-only.
- **Environment overrides**: All `.dockerargs` values can be overridden via environment variables.
