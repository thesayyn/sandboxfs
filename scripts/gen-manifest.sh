
#!/usr/bin/env bash
# Walk a source directory and emit a sandboxfs manifest JSON to stdout.
# Each file becomes a regular-file entry whose `root` points at the real path;
# each directory becomes a `dir: true` entry.
#
# Usage: gen-manifest.sh <source-dir> > manifest.json
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <source-dir>" >&2
  exit 1
fi

python3 - "$1" <<'PY'
import json, os, sys
src = os.path.abspath(sys.argv[1])
entries = []
for root, dirs, files in os.walk(src):
    for d in sorted(dirs):
        rel = os.path.relpath(os.path.join(root, d), src)
        entries.append({"path": rel, "dir": True})
    for f in sorted(files):
        full = os.path.join(root, f)
        rel = os.path.relpath(full, src)
        entries.append({"path": rel, "root": full})
json.dump(entries, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
