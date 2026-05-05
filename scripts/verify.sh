#!/usr/bin/env bash
# End-to-end smoke test for the pread read path:
#   1. Create a temp source tree with a few fixture files.
#   2. Generate a manifest pointing at those files.
#   3. Mount it.
#   4. For every file, diff the bytes read through the mount against the source.
#   5. Unmount.
#
# Assumes scripts/build.sh and scripts/install.sh have already been run and
# the extension is enabled in System Settings.
set -euo pipefail

cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/sandboxfs-verify.XXXXXX)"
SRC="$TMP/src"
MNT="$TMP/mnt"
MANIFEST="$TMP/manifest.json"

cleanup() {
  if mount | grep -q " on $MNT "; then
    sudo umount "$MNT" 2>/dev/null || sudo diskutil unmount force "$MNT" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$SRC/sub/deeper"
echo "hello, world" > "$SRC/hello.txt"
printf 'line 1\nline 2\nline 3\n' > "$SRC/sub/multi.txt"
# A larger file to exercise multi-page reads.
dd if=/dev/urandom of="$SRC/sub/deeper/blob.bin" bs=1024 count=64 2>/dev/null

echo "Source tree:"
find "$SRC" -type f | sed "s|^$SRC/|  |"

echo
echo "Generating manifest..."
scripts/gen-manifest.sh "$SRC" > "$MANIFEST"

echo
echo "Mounting..."
mkdir -p "$MNT"
scripts/mount.sh "$MANIFEST" "$MNT"

echo
echo "Verifying reads..."
fail=0
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  if diff -q "$f" "$MNT/$rel" >/dev/null; then
    echo "  OK   $rel"
  else
    echo "  FAIL $rel"
    fail=1
  fi
done < <(find "$SRC" -type f -print0)

echo
if [ $fail -eq 0 ]; then
  echo "All reads verified."
else
  echo "Some reads failed." >&2
  exit 1
fi
