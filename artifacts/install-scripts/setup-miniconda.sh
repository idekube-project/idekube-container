#!/bin/bash
set -e

: "${MINICONDA_VERSION:?MINICONDA_VERSION is not set (versions are pinned in docker-bake.hcl)}"

# Install Miniconda
arch=$(uname -m)
if [ "$arch" = "arm64" ]; then arch="aarch64"; fi

wget -q "https://repo.continuum.io/miniconda/Miniconda3-${MINICONDA_VERSION}-Linux-$arch.sh" -O /tmp/miniconda.sh
/bin/bash /tmp/miniconda.sh -b -p /opt/miniconda3
rm /tmp/miniconda.sh
/opt/miniconda3/bin/conda init --system bash
/opt/miniconda3/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
/opt/miniconda3/bin/conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main