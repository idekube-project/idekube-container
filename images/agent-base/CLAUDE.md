# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Base image project for the **agent** flavor — AI agent toolchain (Claude Code + opencode) + ttyd web terminal + SSH. Produces `agent/base` image. Part of the [idekube-container](https://github.com/idekube-project/idekube-container) project.

## Build Commands

```bash
make prepare                  # Init submodules + create symlinks (artifacts, healthcheck, frontend)
make build                    # Build agent/base image locally
make build LINEUP=ascend      # Build for Ascend NPU (arm64-only)
make publishx                 # Multi-arch build + push to ghcr.io
make tag-stable               # Retag current version as stable
```

## Project Structure

- **`config.json`** — Registry (`ghcr.io`), author (`idekube-project`), architectures, lineup definitions
- **`.dockerargs.base`** — Build-time variables (BASE_IMAGE, CLAUDE_CODE_VERSION, OPENCODE_VERSION, TTYD_VERSION, NODE_MAJOR, etc.)
- **`.dockerargs.ascend`** — Build-time variables for Ascend lineup
- **`docker/base/`** — Dockerfile + `images.json` + install-scripts:
  - `setup-claude-code.sh` — npm install @anthropic-ai/claude-code
  - `setup-opencode.sh` — OpenCode IDE
  - `setup-ttyd.sh` — Terminal over websocket
  - `setup-agent-tools.sh` — Agent tooling
  - `setup-nvm.sh` — Node.js via NVM
  - `setup-docproc.sh` — Document processing
- **`artifacts/docker/agent/rootfs/`** — nginx proxy config, supervisor conf, health.json

## CI/CD

GitHub Actions workflow (`.github/workflows/publish.yml`) calls the reusable workflow from `idekube-project/idekube-container-docker-builder`. Triggers on `v*` tags or manual dispatch. Authenticates to GHCR via `GITHUB_TOKEN`.

## Key Concepts

- **Symlink prepare step**: `make prepare` creates symlinks for artifacts, healthcheck, and frontend. Requires Node.js 22 for frontend build.
- **Stable tag**: After verification, `make tag-stable` retags the image. Derived images (`agent/openclaw`, `agent/hermes`) `FROM` this stable tag.
- **Lineups**: `base` lineup for amd64+arm64 from `ubuntu:24.04`. `ascend` lineup for arm64-only from `ascendai/cann`.
