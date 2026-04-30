# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Base image project for the **featured** flavor — full desktop with XFCE + noVNC (TurboVNC + VirtualGL) + Coder + SSH + Miniconda. Produces `featured/base` image. Part of the [idekube-container](https://github.com/idekube-project/idekube-container) project.

## Build Commands

```bash
make prepare                  # Init submodules + create symlinks (artifacts, healthcheck, frontend)
make build                    # Build featured/base image locally
make build LINEUP=ascend      # Build for Ascend NPU (arm64-only)
make publishx                 # Multi-arch build + push to ghcr.io
make tag-stable               # Retag current version as stable
make discover                 # Show discovered images and dependencies
```

## Project Structure

- **`config.json`** — Registry (`ghcr.io`), author (`idekube-project`), architectures, lineup definitions
- **`.dockerargs.base`** — Build-time variables for base lineup (BASE_IMAGE, VGL/TurboVNC versions, etc.)
- **`.dockerargs.ascend`** — Build-time variables for Ascend lineup (arm64-only, `ascendai/cann` base)
- **`docker/base/`** — Dockerfile + `images.json` + `install-scripts/` (setup-vgl.sh, setup-desktop.sh, setup-vnc.sh, setup-chromium.sh)
- **`artifacts/docker/featured/rootfs/`** — XFCE desktop config, supervisor conf, nginx conf, health.json
- **`qemu/base/`** — QEMU VM variant with Ansible provisioning (`install.yml`)

## CI/CD

GitHub Actions workflow (`.github/workflows/publish.yml`) calls the reusable workflow from `idekube-project/idekube-container-docker-builder`. Triggers on `v*` tags or manual dispatch. Authenticates to GHCR via `GITHUB_TOKEN`.

## Key Concepts

- **Symlink prepare step**: `make prepare` creates symlinks under `third_party/` and `artifacts/` pointing to submodule paths. Dockerfiles use `RUN --mount=type=bind` to reference these.
- **Multi-stage build**: Healthcheck Go binary is compiled in a builder stage, then copied into the final image.
- **Frontend**: Built from source during `make prepare` (requires Node.js 22), output served by nginx.
- **Stable tag**: After verification, `make tag-stable` retags the image. Derived images (`featured/speit`, `featured/dind`, etc.) `FROM` this stable tag.
- **Lineups**: `base` lineup builds for amd64+arm64 from `ubuntu:24.04`. `ascend` lineup builds arm64-only from `ascendai/cann`.
- **Environment overrides**: All `.dockerargs` values can be overridden via environment variables. `REGISTRY` and `AUTHOR` override `config.json` values.
