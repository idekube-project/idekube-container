#!/bin/bash

# check the id of the current user
CURRENT_UID=$(id -u)
if [ "$CURRENT_UID" -ne 0 ]; then
    echo "This script must be run as root. Current UID: $CURRENT_UID"
    exit 1
fi

# check if /rootfs is mounted to another volume
if ! mountpoint -q /rootfs; then
    echo "/rootfs is not mounted to another volume. Exiting."
    exit 0 # also exit successfully
else
    # check the /rootfs mountpoint
    echo "/rootfs is mounted to $(mountpoint -d /rootfs)."
fi

# Only seed /rootfs once: re-running would wipe whatever the persisted root
# filesystem accumulated since. IDEKUBE_ROOTFS_RESET=true forces a fresh copy;
# false (or a templated empty value) never does, and anything else stops here.
# shellcheck source=/dev/null
source /usr/local/lib/idekube/env.sh
ROOTFS_RESET=$(idekube_bool IDEKUBE_ROOTFS_RESET) || exit 1
MARKER=/rootfs/.idekube-rootfs-initialized
if [ -f "$MARKER" ] && [ "$ROOTFS_RESET" != 1 ]; then
    echo "/rootfs is already initialized ($MARKER exists). Set IDEKUBE_ROOTFS_RESET=true to re-sync. Skipping."
    exit 0
fi

# Clean /rootfs
rm -rf /rootfs/* /rootfs/.*

# Use rsync to mirror the root filesystem to /rootfs with proper exclusions
chmod 755 /rootfs && chown root:root /rootfs

echo "Syncing root filesystem to /rootfs..."
rsync -aAXH --info=progress2 \
  --exclude=/rootfs \
  --exclude=/proc/* \
  --exclude=/sys/* \
  --exclude=/dev/* \
  --exclude=/run/* \
  --exclude=/tmp/* \
  --exclude=/mnt/* \
  --exclude=/media/* \
  --exclude=/var/tmp/* \
  --exclude=/var/run/* \
  --exclude=/lost+found \
  --exclude=/boot \
  / /rootfs/
rsync_status=$?
# 24 means some source files vanished mid-copy, which is harmless on a live root.
if [ "$rsync_status" -ne 0 ] && [ "$rsync_status" -ne 24 ]; then
    echo "rsync failed with exit code $rsync_status; /rootfs is left uninitialized." >&2
    exit 1
fi

# Create essential directories that were excluded
mkdir -p /rootfs/{proc,sys,dev,run,tmp,mnt,media,var/tmp,var/run}

touch "$MARKER"

# exit successfully
echo "Init container completed successfully."
exit 0