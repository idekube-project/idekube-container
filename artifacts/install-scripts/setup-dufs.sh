#!/bin/bash
set -e

# Fail if $DUFS_VERSION is not set
if [ -z "$DUFS_VERSION" ]; then
    echo "DUFS_VERSION is not set"
    exit 1
fi

# Detect the architecture and map to the dufs release target triple
case "$(uname -m)" in
    x86_64)  target="x86_64-unknown-linux-musl" ;;
    aarch64) target="aarch64-unknown-linux-musl" ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

asset="dufs-v${DUFS_VERSION}-${target}.tar.gz"
wget -q "https://github.com/sigoden/dufs/releases/download/v${DUFS_VERSION}/${asset}" \
    -O "${tmpdir}/${asset}"
tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}" dufs
install -m 0755 "${tmpdir}/dufs" /usr/local/bin/dufs
