#!/usr/bin/env bash
# One-shot: build with proper entitlements, register, mount, run hyperfine, unmount.
#
# Prereqs (one-time, manual):
#   - Open the project in Xcode at least once and hit Run on the `sandbox` scheme.
#   - In System Settings -> Login Items & Extensions -> By Category -> FSKit Modules,
#     toggle weldfs on. (It may need re-toggle after entitlement changes.)
#
# After that, just run this script repeatedly.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine not found. Install: brew install hyperfine" >&2
  exit 1
fi

LARGE_MB="${LARGE_MB:-100}"
SMALL_COUNT="${SMALL_COUNT:-2000}"
SMALL_KB="${SMALL_KB:-4}"
WARMUP="${WARMUP:-3}"
RUNS="${RUNS:-10}"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Locate the Xcode-built app in DerivedData (latest matching sandbox.app).
APP=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 -type d -name sandbox.app -path '*/Build/Products/Debug/sandbox.app' 2>/dev/null \
        | xargs -I{} stat -f '%m {}' {} 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "Could not locate sandbox.app in DerivedData. Build via Xcode Run first." >&2
  exit 1
fi
APPEX="$APP/Contents/Extensions/weldfs.appex"

TMP="$(mktemp -d /tmp/weldfs-bench.XXXXXX)"
SRC="$TMP/src"
MNT="$TMP/mnt"
MANIFEST="$TMP/manifest.json"

cleanup() {
  if mount | grep -q " on $MNT "; then
    sudo umount "$MNT" 2>/dev/null || sudo diskutil unmount force "$MNT" 2>/dev/null || true
  fi
  # Wait for the kernel to release the mountpoint before rm-ing the parent.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    mount | grep -q " on $MNT " || break
    sleep 0.2
  done
  # Give the extension a moment to flush its op-count log on deactivate,
  # then surface the counters here.
  sleep 0.5
  echo
  echo "=== weldfs op counts (from log) ==="
  log show --info --last 30s --style compact --predicate 'subsystem == "weldfs"' 2>/dev/null \
    | awk '/=== weldfs op counts ===/,0' \
    | head -30
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Using build at: $APP"
echo "==> Signed entitlements on weldfs.appex:"
codesign -d --entitlements - "$APPEX" 2>&1 | grep -vE "^Executable" | sed 's/^/    /'

# Stale mount cleanup
sudo umount /tmp/wfs_mnt 2>/dev/null || true
sudo umount "$MNT" 2>/dev/null || true

echo "==> Generating fixtures (large=${LARGE_MB} MiB, small=${SMALL_COUNT}x${SMALL_KB} KiB)"
mkdir -p "$SRC/large" "$SRC/many" "$MNT"
dd if=/dev/urandom of="$SRC/large/blob.bin" bs=1m count="$LARGE_MB" 2>/dev/null
for i in $(seq 1 "$SMALL_COUNT"); do
  dd if=/dev/urandom of="$SRC/many/file_$i.bin" bs=1k count="$SMALL_KB" 2>/dev/null
done

echo "==> Generating manifest"
scripts/gen-manifest.sh "$SRC" > "$MANIFEST"

echo "==> Mounting weldfs at $MNT"
if ! sudo mount -F -t weldfs "$MANIFEST" "$MNT" 2>"$TMP/mount.err"; then
  cat "$TMP/mount.err"
  echo
  echo "(Mount failed. If this looks like a registration issue, run:" >&2
  echo "  $LSREGISTER -f -R -trusted '$APP'" >&2
  echo "  pluginkit -a '$APPEX'" >&2
  echo "  sudo killall fskitd" >&2
  echo "Then re-toggle weldfs in System Settings -> By Category -> FSKit Modules.)" >&2
  exit 1
fi

echo "==> Sanity check: read one file"
if ! cat "$MNT/large/blob.bin" > /dev/null 2>"$TMP/cat.err"; then
  echo "FAIL: cat through weldfs returned an error:" >&2
  cat "$TMP/cat.err" >&2
  echo "(Likely the App Sandbox is blocking the backing file path. Check entitlements in the signed appex:" >&2
  echo "  codesign -d --entitlements - $APPEX )" >&2
  exit 1
fi
echo "    ok"

run_bench() {
  local label="$1"; shift
  local direct_cmd="$1"; shift
  local mount_cmd="$1"
  echo
  echo "=== $label ==="
  hyperfine --warmup "$WARMUP" --runs "$RUNS" \
    --command-name "direct" "$direct_cmd" \
    --command-name "weldfs" "$mount_cmd"
}

run_bench "Sequential read (${LARGE_MB} MiB)" \
  "cat $SRC/large/blob.bin > /dev/null" \
  "cat $MNT/large/blob.bin > /dev/null"

run_bench "Many small files (${SMALL_COUNT} x ${SMALL_KB} KiB)" \
  "find $SRC/many -type f -exec cat {} + > /dev/null" \
  "find $MNT/many -type f -exec cat {} + > /dev/null"

run_bench "Stat traversal" \
  "find $SRC -type f -print0 | xargs -0 stat > /dev/null" \
  "find $MNT -type f -print0 | xargs -0 stat > /dev/null"

run_bench "Full tree read" \
  "find $SRC -type f -print0 | xargs -0 cat > /dev/null" \
  "find $MNT -type f -print0 | xargs -0 cat > /dev/null"
