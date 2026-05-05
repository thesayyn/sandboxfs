#!/usr/bin/env bash
# Unmount a sandboxfs volume.
#
# Usage: unmount.sh <mountpoint>
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <mountpoint>" >&2
  exit 1
fi

MOUNTPOINT="$1"

if mount | grep -q " on $MOUNTPOINT "; then
  sudo umount "$MOUNTPOINT" || sudo diskutil unmount force "$MOUNTPOINT"
else
  echo "Nothing mounted at $MOUNTPOINT" >&2
fi
