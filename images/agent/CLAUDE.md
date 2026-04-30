# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Derived image project for the **agent** flavor. Builds on top of `agent/base` (stable tag). Produces variants: `openclaw`, `hermes`. Part of the [idekube-container](https://github.com/idekube-project/idekube-container) project.

## Build Commands

```bash
make prepare                              # Init submodules
make build BRANCH=agent/openclaw          # Build a specific variant
make build-all                            # Build all variants in DAG order
make publishx BRANCH=agent/openclaw       # Multi-arch build + push single variant
make publishx-all                         # Build + push all variants
make publishx-all LINEUP=ascend           # Build all for Ascend lineup
make discover                             # Show image DAG
```

## Project Structure

- **`config.json`** — Registry (`ghcr.io`), author (`idekube-project`), architectures, lineup definitions
- **`docker/openclaw/`** — openclaw agent gateway at `/agent`
- **`docker/hermes/`** — Hermes Agent CLI + gateway

## CI/CD

GitHub Actions workflow (`.github/workflows/publish.yml`) calls the reusable workflow from `idekube-project/idekube-container-docker-builder`. Triggers on `v*` tags or manual dispatch. Authenticates to GHCR via `GITHUB_TOKEN`.

## Key Concepts

- **Stable tag contract**: `FROM ghcr.io/idekube-project/idekube-container:agent-base-stable`. Base must be tagged stable first.
- **Lineups**: `base` lineup for amd64+arm64. `ascend` lineup for arm64-only.
