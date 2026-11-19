#!/usr/bin/env bash
# Short id of the frontend sources, shown on the landing page as the frontend
# build. Reads the object recorded for frontend/ in HEAD: the submodule commit
# while frontend/ is a submodule, its tree id once it is a plain directory.
# Unlike `git -C frontend rev-parse HEAD` it never silently falls back to the
# meta-repo commit, and it works on shallow clones.
set -euo pipefail
cd "$(dirname "$0")/../.."
git rev-parse --short HEAD:frontend 2>/dev/null || echo dev
