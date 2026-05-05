#!/usr/bin/env bash
# Compare read performance: direct filesystem vs weldfs projection.
#
# Generates a fixture tree, mounts weldfs over a manifest pointing at it,
# then runs hyperfine on several access patterns: a large sequential read,
# many small file reads, stat-heavy traversal, and a full tree read.
#
# Assumes weldfs is already built, registered, and enabled in System Settings.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine not found. Install: brew install hyperfine" >&2
  exit 1
fi

TMP="$(mktemp -d /tmp/weldfs-bench.XXXXXX)"
SRC="$TMP/src"
MNT="$TMP/mnt"
MANIFEST="$TMP/manifest.json"

LARGE_MB="${LARGE_MB:-100}"
SMALL_COUNT="${SMALL_COUNT:-2000}"
SMALL_KB="${SMALL_KB:-4}"

cleanup() {
  if mount | grep -q " on $MNT "; then
    sudo umount "$MNT" 2>/dev/null || sudo diskutil unmount force "$MNT" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "Building fixture tree..."
mkdir -p "$SRC/large" "$SRC/many" "$MNT"
dd if=/dev/urandom of="$SRC/large/blob.bin" bs=1m count="$LARGE_MB" 2>/dev/null
for i in $(seq 1 "$SMALL_COUNT"); do
  dd if=/dev/urandom of="$SRC/many/file_$i.bin" bs=1k count="$SMALL_KB" 2>/dev/null
done
echo "  large: ${LARGE_MB} MiB, small: ${SMALL_COUNT} files of ${SMALL_KB} KiB"

echo "Generating manifest..."
scripts/gen-manifest.sh "$SRC" > "$MANIFEST"

echo "Mounting weldfs..."
sudo mount -F -t weldfs "$MANIFEST" "$MNT"

WARMUP=3
RUNS=10

run_bench() {
  local label="$1"; shift
  local direct_cmd="$1"; shift
  local mount_cmd="$1"; shift
  echo
  echo "=== $label ==="
  hyperfine \
    --warmup "$WARMUP" --runs "$RUNS" \
    --command-name "direct" "$direct_cmd" \
    --command-name "weldfs" "$mount_cmd"
}

run_bench "Sequential read (${LARGE_MB} MiB)" \
  "cat $SRC/large/blob.bin > /dev/null" \
  "cat $MNT/large/blob.bin > /dev/null"

run_bench "Many small files: cat all (${SMALL_COUNT} x ${SMALL_KB} KiB)" \
  "find $SRC/many -type f -exec cat {} + > /dev/null" \
  "find $MNT/many -type f -exec cat {} + > /dev/null"

run_bench "Stat-only traversal" \
  "find $SRC -type f -print0 | xargs -0 stat > /dev/null" \
  "find $MNT -type f -print0 | xargs -0 stat > /dev/null"

run_bench "Full tree read" \
  "find $SRC -type f -print0 | xargs -0 cat > /dev/null" \
  "find $MNT -type f -print0 | xargs -0 cat > /dev/null"
