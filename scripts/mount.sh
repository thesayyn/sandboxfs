#!/usr/bin/env bash
# Mount a sandboxfs volume using a manifest as the backing resource.
#
# Usage: mount.sh <manifest.json> <mountpoint>
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <manifest.json> <mountpoint>" >&2
  exit 1
fi

MANIFEST="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
MOUNTPOINT="$2"

mkdir -p "$MOUNTPOINT"

echo "Mounting $MANIFEST at $MOUNTPOINT"
sudo mount -F -t sandboxfs "$MANIFEST" "$MOUNTPOINT"

echo
mount | grep "$MOUNTPOINT" || true
