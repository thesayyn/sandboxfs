#!/usr/bin/env bash
# Compare per-syscall costs between direct APFS and weldfs.
#
# Builds a fixture once, profiles a Python stat-loop against it twice:
#   1) directly on the source dir (APFS)
#   2) through weldfs over a manifest of the same files
# Then aggregates syscall counts and average durations from each trace.
#
# Prereqs: extension built and toggled on (same as scripts/bench.sh).
set -euo pipefail

cd "$(dirname "$0")/.."

DURATION="${DURATION:-10}"
SMALL_COUNT="${SMALL_COUNT:-20000}"
WORKLOAD="${WORKLOAD:-stat}"

if ! command -v xctrace >/dev/null 2>&1; then
  echo "xctrace not found. Install Xcode." >&2
  exit 1
fi

TMP="$(mktemp -d /tmp/weldfs-compare.XXXXXX)"
SRC="$TMP/src"
MNT="$TMP/mnt"
MANIFEST="$TMP/manifest.json"
TRACE_DIRECT="$TMP/direct.trace"
TRACE_WELDFS="$TMP/weldfs.trace"

cleanup() {
  if mount | grep -q " on $MNT "; then
    sudo umount "$MNT" 2>/dev/null || sudo diskutil unmount force "$MNT" 2>/dev/null || true
  fi
  for _ in 1 2 3 4 5; do
    mount | grep -q " on $MNT " || break
    sleep 0.2
  done
  echo "Traces preserved at:"
  echo "  $TRACE_DIRECT"
  echo "  $TRACE_WELDFS"
  echo "(rm -rf $TMP when done)"
}
trap cleanup EXIT

echo "==> Building fixture: $SMALL_COUNT files in $SRC"
mkdir -p "$SRC/sub" "$MNT"
for i in $(seq 1 "$SMALL_COUNT"); do
  printf '%s\n' "$i" > "$SRC/sub/f$i"
done

run_trace() {
  local target="$1"; local out="$2"; local label="$3"
  echo "==> [$label] Recording trace -> $out"
  rm -rf "$out"
  xctrace record \
    --template 'System Trace' \
    --all-processes \
    --time-limit "${DURATION}s" \
    --output "$out" \
    >/dev/null 2>&1 &
  local trace_pid=$!
  sleep 1
  python3 - "$target" "$WORKLOAD" "$trace_pid" <<'PY' &
import os, sys
target, workload, trace_pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
def alive(pid):
    try: os.kill(pid, 0); return True
    except OSError: return False
files = []
for root, dirs, fs in os.walk(target):
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
PY
  local work_pid=$!
  wait $trace_pid
  kill $work_pid 2>/dev/null || true
  wait $work_pid 2>/dev/null || true
}

aggregate() {
  local trace="$1"
  local label="$2"
  xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="syscall"]' 2>/dev/null \
    | python3 - "$label" <<'PY'
import sys, re
label = sys.argv[1]
text = sys.stdin.read()

# All defined ids -> values
proc_names    = {}     # id -> "python3.11"
syscall_names = {}     # id -> "stat64"
duration_ns   = {}     # id -> int

proc_def    = re.compile(r'<process id="([0-9]+)" fmt="([^"(]+)\(([0-9]+)\)"')
syscall_def = re.compile(r'<syscall id="([0-9]+)" fmt="([^"]+)"')
dur_def     = re.compile(r'<duration id="([0-9]+)"[^>]*>([0-9]+)</duration>')

for m in proc_def.finditer(text):    proc_names[m.group(1)]    = m.group(2).strip()
for m in syscall_def.finditer(text):  syscall_names[m.group(1)] = m.group(2)
for m in dur_def.finditer(text):      duration_ns[m.group(1)]   = int(m.group(2))

# Per-row regexes that handle BOTH defined and ref'd attributes.
proc_inline    = re.compile(r'<process id="([0-9]+)" fmt="([^"(]+)\(([0-9]+)\)"')
proc_refd      = re.compile(r'<process ref="([0-9]+)"')
syscall_inline = re.compile(r'<syscall id="([0-9]+)" fmt="([^"]+)"')
syscall_refd   = re.compile(r'<syscall ref="([0-9]+)"')
dur_inline     = re.compile(r'<duration id="([0-9]+)"[^>]*>([0-9]+)</duration>')
dur_refd       = re.compile(r'<duration ref="([0-9]+)"')

def field(row, inline_re, ref_re, lookup):
    im = inline_re.search(row)
    if im: return im.group(2)
    rm = ref_re.search(row)
    if rm: return lookup.get(rm.group(1))
    return None

counts = {}
total_ns = {}
rows = re.split(r'<row>', text)
for row in rows:
    proc = field(row, proc_inline, proc_refd, proc_names)
    if not proc or not proc.startswith("python"):
        continue
    sname = field(row, syscall_inline, syscall_refd, syscall_names)
    ns_str = field(row, dur_inline, dur_refd, duration_ns)
    if sname is None or ns_str is None:
        continue
    ns = int(ns_str) if isinstance(ns_str, str) else ns_str
    counts[sname]   = counts.get(sname, 0) + 1
    total_ns[sname] = total_ns.get(sname, 0) + ns

total = sum(total_ns.values())
print(f"\n{label}")
print(f"  total syscall time on python threads: {total/1e6:.1f} ms")
print(f"  {'syscall':<20} {'count':>10} {'total ms':>10} {'avg µs':>8}")
for s in sorted(total_ns, key=lambda k: -total_ns[k])[:8]:
    n = counts[s]
    avg = total_ns[s] / n
    print(f"  {s:<20} {n:>10} {total_ns[s]/1e6:>10.1f} {avg/1000:>8.2f}")
PY
}

echo "==> Profiling DIRECT (APFS)"
run_trace "$SRC" "$TRACE_DIRECT" "direct"

echo "==> Generating manifest"
scripts/gen-manifest.sh "$SRC" > "$MANIFEST"

echo "==> Mounting weldfs"
sudo mount -F -t weldfs "$MANIFEST" "$MNT"

echo "==> Profiling WELDFS"
run_trace "$MNT" "$TRACE_WELDFS" "weldfs"

echo
echo "============================================================"
echo " Comparison: direct APFS vs weldfs"
echo " (per-syscall durations on the python3 worker thread)"
echo "============================================================"
aggregate "$TRACE_DIRECT" "DIRECT (APFS)"
aggregate "$TRACE_WELDFS" "WELDFS"
