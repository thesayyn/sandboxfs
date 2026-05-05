#!/usr/bin/env bash
# Profile weldfs with Instruments / xctrace System Trace.
#
# Sets up a small fixture, mounts weldfs, then records a System Trace of
# *all* processes (with kernel callstacks) while we run a stat-traversal
# workload through the mount. Result: a .trace bundle you can open in
# Instruments to see kernel-side hotspots in the FSKit VFS path.
#
# Prereqs: extension built via Xcode Run, weldfs toggled on in System
# Settings -> By Category -> FSKit Modules.
set -euo pipefail

cd "$(dirname "$0")/.."

DURATION="${DURATION:-15}"             # seconds of trace recording
SMALL_COUNT="${SMALL_COUNT:-20000}"    # files in the fixture (large = workload takes >5s)
WORKLOAD="${WORKLOAD:-stat}"           # stat | cat | walk
OUTPUT="${OUTPUT:-/tmp/weldfs-profile.trace}"

if ! command -v xctrace >/dev/null 2>&1; then
  echo "xctrace not found. Install Xcode (full version, not just CLT)." >&2
  exit 1
fi

TMP="$(mktemp -d /tmp/weldfs-profile.XXXXXX)"
SRC="$TMP/src"
MNT="$TMP/mnt"
MANIFEST="$TMP/manifest.json"

cleanup() {
  if mount | grep -q " on $MNT "; then
    sudo umount "$MNT" 2>/dev/null || sudo diskutil unmount force "$MNT" 2>/dev/null || true
  fi
  for _ in 1 2 3 4 5; do
    mount | grep -q " on $MNT " || break
    sleep 0.2
  done
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Building fixture: $SMALL_COUNT files"
mkdir -p "$SRC/sub" "$MNT"
for i in $(seq 1 "$SMALL_COUNT"); do
  printf '%s\n' "$i" > "$SRC/sub/f$i"
done

echo "==> Generating manifest"
scripts/gen-manifest.sh "$SRC" > "$MANIFEST"

echo "==> Mounting weldfs"
if ! sudo mount -F -t weldfs "$MANIFEST" "$MNT" 2>"$TMP/mount.err"; then
  cat "$TMP/mount.err" >&2
  echo "(Make sure weldfs is enabled in System Settings -> By Category -> FSKit Modules)" >&2
  exit 1
fi

# Pre-warm: run the workload once before the trace so paths are resolved
# (otherwise the trace captures one-time setup noise, not steady-state behavior).
echo "==> Pre-warming"
case "$WORKLOAD" in
  stat) find "$MNT" -type f -print0 | xargs -0 stat > /dev/null ;;
  cat)  find "$MNT" -type f -print0 | xargs -0 cat  > /dev/null ;;
  walk) find "$MNT" > /dev/null ;;
  *) echo "Unknown WORKLOAD: $WORKLOAD" >&2; exit 1 ;;
esac

rm -rf "$OUTPUT"
echo "==> Recording ${DURATION}s System Trace -> $OUTPUT"
xctrace record \
  --template 'System Trace' \
  --all-processes \
  --time-limit "${DURATION}s" \
  --output "$OUTPUT" \
  >/dev/null 2>&1 &
TRACE_PID=$!

# Run the workload as ONE long-lived Python process doing many syscalls.
# A bash `find | xargs stat` loop forks too much and the trace ends up
# dominated by runningboardd + logd doing process bookkeeping rather than
# the FSKit code we want to see.
sleep 1
echo "==> Running workload loop: $WORKLOAD (single Python process)"
python3 - "$MNT" "$WORKLOAD" "$TRACE_PID" <<'PY' &
import os, sys, time
mnt, workload, trace_pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
def alive(pid):
    try: os.kill(pid, 0); return True
    except OSError: return False
files = []
for root, dirs, fs in os.walk(mnt):
    for f in fs:
        files.append(os.path.join(root, f))
buf = bytearray(65536)
while alive(trace_pid):
    if workload == "stat":
        for p in files:
            try: os.stat(p)
            except FileNotFoundError: pass
    elif workload == "cat":
        for p in files:
            try:
                fd = os.open(p, os.O_RDONLY)
                while os.readv(fd, [memoryview(buf)]) > 0: pass
                os.close(fd)
            except OSError: pass
    elif workload == "walk":
        for _ in os.walk(mnt): pass
PY
WORK_PID=$!

echo "==> Waiting for trace to finish"
wait "$TRACE_PID"
kill "$WORK_PID" 2>/dev/null || true
wait "$WORK_PID" 2>/dev/null || true

echo
echo "Trace saved: $OUTPUT"
echo "Open with:   open $OUTPUT"
echo "Or query:    xctrace export --input $OUTPUT --toc | head"
