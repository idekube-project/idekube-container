#!/bin/bash
set -e

# Exact apt versions from the packagecloud repos, e.g. 3.3.1-20260820.
# docker-bake.hcl is the source of truth; fail rather than float to "latest".
: "${VIRTUALGL_VERSION:?VIRTUALGL_VERSION is not set}"
: "${TURBOVNC_VERSION:?TURBOVNC_VERSION is not set}"

# Add the GPG keys for VirtualGL and TurboVNC
wget -q -O- https://packagecloud.io/dcommander/virtualgl/gpgkey | gpg --dearmor >/etc/apt/trusted.gpg.d/VirtualGL.gpg
wget -q -O- https://packagecloud.io/dcommander/turbovnc/gpgkey | gpg --dearmor >/etc/apt/trusted.gpg.d/TurboVNC.gpg

# Add the package repositories for VirtualGL and TurboVNC. Written inline
# (same content as github.com/{VirtualGL,TurboVNC}/repo main/*.list) instead
# of downloading the list files from a moving branch at build time.
echo "deb [signed-by=/etc/apt/trusted.gpg.d/VirtualGL.gpg] https://packagecloud.io/dcommander/virtualgl/any/ any main" \
    > /etc/apt/sources.list.d/VirtualGL.list
echo "deb [signed-by=/etc/apt/trusted.gpg.d/TurboVNC.gpg] https://packagecloud.io/dcommander/turbovnc/any/ any main" \
    > /etc/apt/sources.list.d/TurboVNC.list

# Update the package lists and install VirtualGL and TurboVNC
apt-get update
apt-get install -y "virtualgl=${VIRTUALGL_VERSION}" "turbovnc=${TURBOVNC_VERSION}"

# Clean up
apt-get autoclean -y && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# FIXME: This is a workaround for a bug in the TurboVNC package
ln -s /usr/share/xsessions/xfce.desktop /usr/share/xsessions/ubuntu.desktop
