# FSKit on macOS 26 — gotchas

A running list of things that cost real debugging time while building this
extension. Most are platform/Xcode oddities, not bugs in the FS code itself.

## SDK / OS / Xcode

- `FSPathURLResource` is **macOS 26+ only**. Not in the macOS 15.4 SDK at all.
  Both the SDK (Xcode 26) **and** the running OS (macOS 26+) must be present;
  Xcode 26 alone on macOS 15 builds, but the symbol doesn't exist at runtime.
- `MACOSX_DEPLOYMENT_TARGET` must be `26.0+` to compile against `FSPathURLResource`.

## Project setup

- **Always start from Xcode's "File System Extension" template.** The public
  `BuildingAPassthroughFileSystem` sample looks similar but uses subtly
  different project metadata; copying its `Info.plist` doesn't reproduce it.
- ExtensionKit-based extensions live in `MyApp.app/Contents/Extensions/` (not
  `Contents/PlugIns/`). Easy to get wrong in install scripts.
- The host can be **faceless** (`LSBackgroundOnly=true`, no GUI). It still
  must be an `.app` bundle; you can't host an FSKit extension from a CLI tool.

## Signing & entitlements

- `ENABLE_APP_SANDBOX=YES` is **required** for FSKit extensions. Setting it to
  `NO` makes ExtensionKit reject the extension load with
  `com.apple.extensionKit.errorDomain error 2`. App-sandbox cannot be turned off.
- The entitlements file is **ignored unless** `CODE_SIGN_ENTITLEMENTS` is set
  in the target's build settings to point at it. Without it, Xcode signs with
  default `app-sandbox=true` + `get-task-allow=true` and silently drops every
  custom entitlement you wrote.
- `com.apple.developer.fskit.fsmodule` must be in the entitlements file *and*
  authorized by the provisioning profile (Apple Development cert covers it for
  free). Without it, `mount` returns "Module is disabled!" even with the
  toggle apparently on.
- `com.apple.security.temporary-exception.files.absolute-path.read-only`
  *does* survive into the signed binary under automatic signing for Apple
  Development. Useful for granting backing-file access beyond the sandbox.

## Building & registering

- `xcodebuild` from the CLI registers the extension with `pluginkit` showing
  version `(null)`, and the extension **never appears in System Settings →
  By Category**. **Open Xcode and hit Run ▶ at least once** — the GUI's
  registration ritual is what makes the extension a first-class FSKit module.
  After that you can rebuild however you want.
- The extension only appears under **By Category → FSKit Modules** if its
  parent app is registered from the Xcode DerivedData path. Custom
  `-derivedDataPath` directories work for `pluginkit` but not for FSKit's
  category enumeration.
- `lsregister -f -R -trusted` re-registers the bundle but **silently disables
  the extension in System Settings**. Only do this when the registration is
  actually broken; otherwise leave it alone and just `killall fskitd`.

## Enabling the extension

- In macOS 26.x, **the "By App" toggle is buggy**: it appears to flip but
  doesn't persist. Toggle from **By Category → FSKit Modules** instead.
  See macfuse/macfuse#1132 for the public bug thread.
- After toggling, **`sudo killall fskitd`** to force the daemon to re-read its
  enablement state. Otherwise `mount` keeps reporting the module as disabled.
- Any change to entitlements or signing **invalidates the previous toggle**.
  Re-toggle in System Settings after each rebuild that affected signing.

## Mounting

- `mount -F -t <fsname>` requires sudo. `diskutil mount` doesn't apply to
  path-URL-backed FSKit volumes — there's no `/dev/diskN` device.
- Common error decoder ring:
  - `Unable to invoke task` → module is disabled (toggle off, or stale fskitd).
  - `Module <id> is disabled!` → same; re-toggle and `killall fskitd`.
  - `invalid file system` → FSKit doesn't know the name; not registered, or
    `FSShortName` mismatch with the `-t` flag.
  - `extensionKit error 2` → ExtensionKit rejected the load (commonly because
    sandbox is off, or the entitlements/profile mismatch).
  - `Probing resource: ... Resource busy` → previous mount on the mountpoint
    is still active; `umount` first.
  - `Operation not permitted` reading a file through the mount → the
    extension's sandbox is blocking access to the backing file path. Add
    a `temporary-exception.files.absolute-path.read-only` entitlement.

## FSKit API quirks

- `FSPathURLResource` requires `FSRequiresSecurityScopedPathURLResources=true`
  in `Info.plist` *and* a call to `url.startAccessingSecurityScopedResource()`
  in `loadResource`, paired with `stopAccessing…` in `unloadResource`.
  Without start-accessing, reading the resource URL returns
  "Operation not permitted" even though the URL points at a real file.
- The security-scoped URL only covers the resource path itself. **Backing
  files referenced *inside* the manifest are not implicitly accessible** —
  they need their own entitlement coverage or per-file bookmarks.
- For projection-style FS, set `FSItem.attributes.size` from `stat(2)` of the
  backing file in `activate()`. Without it, readers see size=0 and stop.
- Cross-volume hardlinks aren't supported (POSIX `EXDEV`). Cross-volume
  `clonefile(2)` either. Symlinks and per-file `pread` are the only practical
  ways to project files from another volume.
- **`umount(8)` does not fire `FSVolume.unmount()` on the extension** in
  macOS 26.4. Neither does it fire `deactivate()`. The kernel tears down
  its mount-table entry without delegating to the extension. If you want
  to dump state at unmount time, expose it via a virtual file inside the
  mount instead (e.g., `cat $MNT/__counters`); a simple `dataProvider`
  closure on an `FSItem` works.
- The kernel buffer cache caches a virtual file's contents based on
  `(size, mtime)`. To force re-reads of a "live" debug file, bump
  `attributes.modifyTime` (and `changeTime`) to the current time on every
  `attributes()` call, AND have `attributes()` recompute `size` from the
  current data length.
- `enumerateDirectory` must:
  1. Iterate from `cookie.rawValue` (not 0) so the kernel can paginate.
  2. Iterate over a **stably-ordered** snapshot (sort `directory.children.keys`)
     so successive calls don't reorder entries mid-iteration.
  3. Check `packEntry`'s return value — `false` means the kernel's pack
     buffer is full; break and let the kernel call back with the
     last-accepted cookie.
  Skipping any of these, especially #3 with a populated dir, hangs `find`.

## Logging & debugging

- The extension's logs are visible via:
  ```bash
  log stream --predicate 'subsystem == "weldfs"' --level info
  ```
  or after the fact:
  ```bash
  log show --last 1m --predicate 'subsystem == "weldfs"'
  ```
- `fskitd` is **on-demand**: `killall fskitd` returns "no matching processes"
  when nothing has triggered it yet. Trigger it by attempting a mount.
- `<private>` redactions in the OS log can be removed by installing Apple's
  Logging configuration profile (referenced in the macFUSE thread above).

## Performance notes

- Symlinks in the projection FS are zero-cost at read time — the kernel
  resolves them once and subsequent reads bypass the extension entirely.
  Trade-off: tools that resolve symlinks see the real path, defeating any
  hermetic-sandboxing intent.
- Regular-file projection via `pread`-on-cached-fd (Apple's passthrough
  pattern) keeps the extension in the data path. Every read pays a Mach/XPC
  round-trip. For large reads this amortizes; for many small reads it's
  the dominant cost.
- True kernel-offloaded I/O (`FSVolumeKernelOffloadedIOOperations`) requires
  block-device backing and isn't available to `FSPathURLResource`-backed
  volumes. There is no FUSE_PASSTHROUGH equivalent in FSKit today.

### Measured numbers (macOS 26.4.1, M-series)

After all optimizations applied (cached fd, `isOpenCloseInhibited`,
read-only mount, capability flags, mmap-cached reads). See `scripts/bench.sh`.

| Workload                   | Direct (warm) | weldfs (warm) | Slowdown |
|----------------------------|---------------|---------------|----------|
| Sequential read (100 MiB)  | 11 ms         | 11 ms         | parity   |
| Many small files (2000×4K) | 37 ms         | 92 ms         | 2.5×     |
| Stat traversal             | 3.10 s        | 4.30 s        | 1.4×     |
| Full tree read             | 52 ms         | 102 ms        | 2.0×     |

Cold cache (`hyperfine --prepare 'sudo purge'` between iterations):
ratios actually *shrink* — 1.2×–1.5× across the board — because direct
APFS loses its kernel-cache advantage when both sides have to fetch from
disk.

Per-syscall comparison via `xctrace` (a flat `os.stat()` loop on 20K
files, profiled directly vs through weldfs):

|                        | Direct (APFS) | weldfs    |
|------------------------|---------------|-----------|
| avg `stat64` duration  | 1.86 µs       | **1.33 µs** |

So `stat64` itself is *faster* on weldfs (in-memory hash lookup beats
APFS's on-disk B-tree for a 20K-entry directory). The 1.4× stat-traversal
slowdown in the macro bench therefore can't be from `stat()`. It comes
from `getdirentries`/`enumerateDirectory` and process-spawn overhead
around the stat calls — those go through FSKit's RPC machinery on cold
paths, and the macro bench's `find | xargs stat` pipeline forks heavily.

**The 70 µs/RPC cost is a cold-path cost only.** In warm steady-state
the kernel cache satisfies most calls without RPC'ing the extension at
all, so per-syscall latency is competitive with native APFS. The
remaining cost lives in directory enumeration and the kernel-side FSKit
VFS bookkeeping that's not user-tunable.

## Profiling with `xctrace` / Instruments

- The default `System Trace` template uses **Windowed (5 s)** recording
  mode. Even with `--time-limit 15s`, only the last 5 s of activity ends
  up in the trace bundle. Either run a long workload that fills the whole
  window, or live with the truncation.
- A `find … | xargs stat` workload forks too aggressively for profiling.
  In the trace, **`runningboardd` and `logd` end up consuming 99% of CPU**
  doing process bookkeeping; the actual filesystem code is invisible.
  Use one long-lived process making many syscalls instead — a Python
  loop calling `os.stat()` is what `scripts/profile.sh` and
  `scripts/compare.sh` use.
- `sudo purge` (drops the unified buffer cache) takes 2–5 s itself. If
  you use it in a tight benchmark loop the trace window mostly captures
  purge waiting, not actual workload. Skip it for profiling; the warm
  steady state is the interesting one anyway.
- Killing a `bash` subshell does **not** kill its `find | xargs stat`
  pipeline (separate processes outlive the parent shell). When the trap
  unmounts the FS, those pipelines start hitting the now-unmounted
  directory and emit `No such file or directory` errors. Cosmetic, not
  a bug in the FS.
- Stack samples in the trace are unsymbolicated PCs unless you have
  dSYMs. System binaries (`libsystem_kernel.dylib`, kernel) have public
  symbols; the syscall table includes nice names like `stat64`. For
  scripted analysis, the `syscall` schema (count + duration per syscall)
  is more useful than `time-sample`.

## SourceKit

- "Cannot find 'X' in scope" errors that disappear after building are
  SourceKit indexing artifacts across multi-file modules. The actual compile
  is fine.
