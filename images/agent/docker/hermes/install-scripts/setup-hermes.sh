#!/bin/bash
set -e

# Pinned refs (set by docker-bake.hcl): a Hermes release tag and a uv version.
# Never fall back to a moving branch such as main.
: "${HERMES_VERSION:?HERMES_VERSION is not set}"
: "${UV_VERSION:?UV_VERSION is not set}"

# Load nvm so npm/node are on PATH
export NVM_DIR="/usr/local/nvm"
. "$NVM_DIR/nvm.sh"

# --- System dependencies not in agent/base ---
apt-get update && apt-get install -y --no-install-recommends ripgrep \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# uv for interactive use in the image. The Hermes installer does not use it:
# it fetches its own sha256-pinned uv and Python (see below).
curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR="/usr/local/bin" sh

# --- Install Hermes Agent ---
# The upstream installer is managed by Hermes' own package manager (pm):
#   <HERMES_HOME>/tools      pinned uv + Python the launcher execs
#   <HERMES_HOME>/installs   dependency environments
#   <checkout>/.hermes/bin/hermes   generated launcher (hard-codes tools/)
# We install into upstream's default layout, rooted at /opt instead of ~:
#   /opt/hermes                 build-time HERMES_HOME (tools/, installs/)
#   /opt/hermes/hermes-agent    the checkout
# At runtime HERMES_HOME is the user's ~/.hermes (config, sessions, memory).
# pm scopes dependency state to the active HERMES_HOME, so a fresh home would
# re-download every dependency on first launch. 00-hermes-bootstrap.sh links
# ~/.hermes/{installs,tools} to /opt/hermes/{installs,tools} so the user's
# home uses exactly what was installed here, offline. Both paths must survive
# the build: a throwaway HERMES_HOME would leave the launcher pointing at a
# deleted Python.
HERMES_ROOT=/opt/hermes
HERMES_SRC=$HERMES_ROOT/hermes-agent
IDEKUBE_USER=${USERNAME:-idekube}

# The installer also edits shell rc files under $HOME; keep those out of
# /home/idekube (shadowed by a volume mount at runtime).
BUILD_HOME=$(mktemp -d)
export HOME="$BUILD_HOME"

curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_VERSION}/scripts/install.sh" \
    | bash -s -- --hermes-home "$HERMES_ROOT" --dir "$HERMES_SRC" --skip-setup --branch "${HERMES_VERSION}"
rm -rf "$BUILD_HOME"

# Publish the generated launcher on the system PATH and make sure it runs:
# a broken install must fail the build, not the container at runtime.
ln -sf "$HERMES_SRC/.hermes/bin/hermes" /usr/local/bin/hermes
HERMES_HOME="$HERMES_ROOT" hermes --help >/dev/null

# --- Default config template ---
# Copied out of the checkout so 00-hermes-bootstrap.sh can seed a config on
# a fresh (volume-mounted) home without network access.
mkdir -p "$HERMES_ROOT/default-config"
cp "$HERMES_SRC/cli-config.yaml.example" "$HERMES_ROOT/default-config/config.yaml"

# --- Permissions ---
# The gateway runs as $IDEKUBE_USER and pm keeps lock/state files in installs/.
chown -R "$IDEKUBE_USER:$IDEKUBE_USER" "$HERMES_ROOT"

# --- Cleanup ---
rm -rf /tmp/pip-* /tmp/uv-*
