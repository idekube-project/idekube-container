#!/usr/bin/env bash
# Short id of the frontend sources, shown on the landing page as the frontend
# build: the tree id of frontend/ in HEAD (a submodule commit id in history
# from before the monorepo).
# Unlike `git -C frontend rev-parse HEAD` it never silently falls back to the
# meta-repo commit, and it works on shallow clones.
set -euo pipefail
cd "$(dirname "$0")/../.."
git rev-parse --short HEAD:frontend 2>/dev/null || echo dev
