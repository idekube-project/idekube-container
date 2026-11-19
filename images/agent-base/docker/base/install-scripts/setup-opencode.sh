#!/bin/bash
set -e

: "${OPENCODE_VERSION:?OPENCODE_VERSION is not set (versions are pinned in docker-bake.hcl)}"

# Load nvm
export NVM_DIR="/usr/local/nvm"
. "$NVM_DIR/nvm.sh"

if [ "${OPENCODE_VERSION}" = "latest" ]; then
    npm install -g opencode-ai
else
    npm install -g opencode-ai@${OPENCODE_VERSION}
fi

opencode --version || true
