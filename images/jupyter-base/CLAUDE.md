# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Base image project for the **jupyter** flavor — JupyterLab + SSH + Miniconda. Produces `jupyter/base` image. Part of the [idekube-container](https://github.com/idekube-project/idekube-container) project.

## Build Commands

```bash
make prepare                  # Init submodules + create symlinks (artifacts, healthcheck, frontend)
make build                    # Build jupyter/base image locally
make build LINEUP=ascend      # Build for Ascend NPU (arm64-only)
make publishx                 # Multi-arch build + push to ghcr.io
make tag-stable               # Retag current version as stable
```

## Project Structure

- **`config.json`** — Registry (`ghcr.io`), author (`idekube-project`), architectures, lineup definitions
- **`.dockerargs.base`** — Build-time variables (BASE_IMAGE, MINICONDA_VERSION, etc.)
- **`.dockerargs.ascend`** — Build-time variables for Ascend lineup
- **`docker/base/`** — Dockerfile + `images.json` + `install-scripts/`
- **`artifacts/docker/`** — Rootfs overlays (supervisor, nginx, health.json)

## CI/CD

GitHub Actions workflow (`.github/workflows/publish.yml`) calls the reusable workflow from `idekube-project/idekube-container-docker-builder`. Triggers on `v*` tags or manual dispatch. Authenticates to GHCR via `GITHUB_TOKEN`.

## Key Concepts

- **Symlink prepare step**: `make prepare` creates symlinks for artifacts, healthcheck, and frontend. Requires Node.js 22 for frontend build.
- **Stable tag**: After verification, `make tag-stable` retags the image. Derived images (`jupyter/speit-ai`, `jupyter/speit-ascendai`) `FROM` this stable tag.
- **Lineups**: `base` lineup for amd64+arm64 from `ubuntu:24.04`. `ascend` lineup for arm64-only from `ascendai/cann`.
