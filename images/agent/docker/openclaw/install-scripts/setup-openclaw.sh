#!/bin/bash
set -e

OPENCLAW_VERSION=${OPENCLAW_VERSION:-latest}
# OpenClaw 2026.9.3+ requires Node >=24.16.0 <25 or >=26.1.0.
# See https://docs.openclaw.ai/install/node-compatibility
OPENCLAW_NODE_MAJOR="${OPENCLAW_NODE_MAJOR:-24}"

# Load nvm so npm is on PATH
export NVM_DIR="/usr/local/nvm"
. "$NVM_DIR/nvm.sh"

# agent-base keeps Node 22 as the nvm default so claude/opencode globals
# stay on PATH via $NVM_DIR/current. Install Node 24 alongside it and
# expose it through a dedicated symlink used only for OpenClaw.
nvm install "$OPENCLAW_NODE_MAJOR"
nvm alias default 22
nvm use "$OPENCLAW_NODE_MAJOR"
ln -sfn "$(dirname "$(nvm which "$OPENCLAW_NODE_MAJOR")")" "$NVM_DIR/openclaw-node"

# Interactive login shells and PAM sessions still prepend $NVM_DIR/current
# (Node 22). Put Node 24 first so `openclaw` and `#!/usr/bin/env node`
# resolve to a supported runtime without hiding claude/opencode.
if [ -f /etc/environment ]; then
    sed -i 's|/usr/local/nvm/current|/usr/local/nvm/openclaw-node:/usr/local/nvm/current|' /etc/environment
fi

if [ "${OPENCLAW_VERSION}" = "latest" ]; then
    curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
else
    curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard --version "${OPENCLAW_VERSION}"
fi

openclaw --version

# Bootstrap default local config so the gateway starts without manual setup.
# Run as the container user so config lands in their home directory.
IDEKUBE_USER=${USERNAME:-idekube}
IDEKUBE_HOME=$(eval echo "~$IDEKUBE_USER")

# Login shells source profile.d/nvm.sh (Node 22). Prepend the OpenClaw
# Node 24 bin dir so `openclaw` does not re-exec under the unsupported
# runtime.
OPENCLAW_PATH="export PATH=/usr/local/nvm/openclaw-node:\$PATH"

su - "$IDEKUBE_USER" -c "$OPENCLAW_PATH && \
  openclaw onboard --non-interactive --accept-risk --mode local \
    --auth-choice skip --skip-channels --skip-daemon --skip-health \
    --skip-search --skip-skills --skip-ui --no-install-daemon"

# Tell openclaw it is being served under /agent so the Control UI HTML
# is mounted at /agent/ and the bundled JS derives WebSocket URLs that
# match what nginx proxies. Without this, the UI tries to open a
# WebSocket at the document path (e.g. /agent) but openclaw responds
# with a 302 redirect, which WebSocket clients cannot follow.
su - "$IDEKUBE_USER" -c "$OPENCLAW_PATH && \
  openclaw config set gateway.controlUi.basePath '\"/agent\"' --strict-json"

# Allow Control UI WebSocket connections from any browser origin. The
# gateway is reverse-proxied behind nginx (potentially under any
# host/port the user exposes the container at), so we cannot enumerate
# origins ahead of time. The wildcard is acceptable here because the
# token-based auth still gates access; the schema warns against using
# this outside controlled deployments — this image is exactly that.
su - "$IDEKUBE_USER" -c "$OPENCLAW_PATH && \
  openclaw config set gateway.controlUi.allowedOrigins '[\"*\"]' --strict-json"

# Remove runtime state that should not be baked into the image.
# The gateway will regenerate these on first start.
rm -rf "$IDEKUBE_HOME/.openclaw/logs" \
       "$IDEKUBE_HOME/.openclaw/tasks" \
       "$IDEKUBE_HOME/.openclaw/update-check.json"

# Strip the generated auth token — a fresh one will be created at runtime
# or the user can configure their own.
su - "$IDEKUBE_USER" -c "$OPENCLAW_PATH && \
  openclaw config unset gateway.auth.token" 2>/dev/null || true

# Drop the .bak files left behind by the config writes above. The
# gateway can regenerate these on first start if it needs them.
rm -f "$IDEKUBE_HOME/.openclaw"/openclaw.json.bak*
