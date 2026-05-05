# FSKit notes

Reference and findings about Apple's FSKit framework, gathered while building
this projection-style filesystem for macOS 26.

## Resource types (how the FS gets mounted)

FSKit volumes are activated with an `FSResource`. Three concrete subclasses
exist; the choice is wired in `Info.plist` via `FSSupportsBlockResources`,
`FSSupportsPathURLs`, `FSSupportsGenericURLResources`, `FSSupportsServerURLs`:

- **`FSBlockDeviceResource`** — backed by a `/dev/diskN` device. Required for
  block-format filesystems. Necessary if you want to use
  `FSVolumeKernelOffloadedIOOperations`.
- **`FSPathURLResource`** — backed by a local `file://` URL. Pair with
  `FSRequiresSecurityScopedPathURLResources=true` and
  `url.startAccessingSecurityScopedResource()` in `loadResource`.
- **`FSGenericURLResource`** — backed by an arbitrary URL (any scheme). For
  filesystems that resolve their backing through a custom protocol.

## Filesystem entry point

```swift
@main struct MyFS: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations { ... }
}
```

The `FSUnaryFileSystemOperations` class implements:

- `probeResource(_:replyHandler:)` — describe whether you recognize this
  resource. Return `FSProbeResult.usable(name:containerID:)`.
- `loadResource(_:options:replyHandler:)` — produce an `FSVolume` for the
  resource. Set `containerStatus = .ready` here.
- `unloadResource(_:options:replyHandler:)` — release the resource. Stop
  security-scoped access here.

## Volume operations protocols

`FSVolume` itself is just an identity (volume UUID, name). Behavior is
attached via opt-in protocols. Each one corresponds to a class of kernel
calls; conforming to it tells the kernel "I can handle these."

### Required

- **`FSVolumeOperations`** (which extends `FSVolumePathConfOperations`) — the
  big one. mount/unmount/synchronize, lookupItem, attributes, setAttributes,
  reclaimItem, readSymbolicLink, createItem, createSymbolicLink, createLink,
  removeItem, renameItem, enumerateDirectory, activate, deactivate.

### Optional

| Protocol | Purpose | Inhibitor |
|---|---|---|
| `FSVolumeOpenCloseOperations` | `openItem` / `closeItem` per-handle hooks | `isOpenCloseInhibited` |
| `FSVolumeReadWriteOperations` | `read(from:at:length:into:)` / `write(contents:to:at:)` | (none) |
| `FSVolumeXattrOperations` | xattr get/set/list | `xattrOperationsInhibited` |
| `FSVolumeAccessCheckOperations` | `checkAccessToItem` for ACL checks | `accessCheckInhibited` |
| `FSVolumeRenameOperations` | volume-level rename (`setVolumeName`) | `volumeRenameInhibited` |
| `FSVolumePreallocateOperations` | `preallocateSpace(for:at:length:flags:)` | `preallocateInhibited` |
| `FSVolumeItemDeactivation` | `deactivateItem` (inode reclaim hook) | (policy property) |
| `FSVolumeKernelOffloadedIOOperations` | extent-mapped kernel I/O (block FS only) | per-item `inhibitKernelOffloadedIO` |
| `FSManageableResourceMaintenanceOperations` | resource-level fsck/format | (none) |

### The `*Inhibited` pattern

Every optional protocol that has an inhibitor lets you conform statically but
disable at runtime:

```swift
@objc var isOpenCloseInhibited: Bool { true }
```

When true, the kernel **does not call** the protocol's methods, even though
you conform. Useful when:

- You don't actually need the per-handle state (we don't — fds are cached
  for the volume's lifetime), so `openItem`/`closeItem` round-trips are pure
  XPC overhead.
- You want different runtime behavior on different volumes / mounts without
  refactoring the conformance.

The Swift compiler emits a "nearly matches optional requirement" warning
because of `@objc Bool` vs ObjC `BOOL` bridging; the warning is cosmetic — the
runtime honors the property.

### `requestedMountOptions`

```swift
@objc var requestedMountOptions: FSVolume.MountOptions { .readOnly }
```

Tell the kernel to mount this volume read-only by default. Skips entire
classes of write-side RPCs (createItem, write, removeItem, setAttributes,
rename) that the kernel would otherwise speculatively send.

## Attributes

`FSItemAttributes` (and its `Set`/`Get` request siblings) carries the usual
POSIX metadata plus a couple of FSKit-specific knobs:

- `supportsLimitedXAttrs` — per-item xattr capability hint.
- `inhibitKernelOffloadedIO` — per-item opt-out from the kernel-offloaded
  I/O path (matters only if you conform to
  `FSVolumeKernelOffloadedIOOperations`).

`FSItemGetAttributesRequest.wantedAttributes` and
`FSItemSetAttributesRequest.consumedAttributes` use the `FSItemAttribute`
options bitmap to tell you which fields are actually being asked for or set.
You should check `request.isValid(.size)` etc. before reading/writing each
field.

## `FSVolumeSupportedCapabilities`

A wide pile of feature toggles the FS reports to the kernel. Setting these
correctly tells the kernel what it can and can't ask for, which can avoid
RPCs entirely. The interesting ones for a projection FS:

- `supportsHardLinks` — kernel won't attempt `link(2)` if false.
- `supportsSymbolicLinks` — kernel won't attempt `symlink(2)` if false.
- `supportsHiddenFiles`, `supportsPersistentObjectIDs`,
  `supports64BitObjectIDs`, `caseFormat = .insensitiveCasePreserving` — what
  we use.
- `supportsFastStatFS` — fast `statfs` path (kernel may cache).
- `doesNotSupportRootTimes` — skip timestamp queries on the root inode.
- `supportsSparseFiles`, `supportsZeroRuns`, `supports2TBFiles`,
  `supportsJournal`, `supportsActiveJournal` — block-FS-shaped flags, no-op
  for projection FSes.

## Read/write data path

`read` / `write` give you a `FSMutableFileDataBuffer`. You fill it via
`buffer.withUnsafeMutableBytes { dst in pread(fd, dst.baseAddress, len, off) }`
and return the count.

The kernel decides the read size (typically 64 KiB up to several MiB for
large sequential reads). Each `read` call is one XPC RPC into your
extension; we measured ~70 μs per RPC on a quiet M-series machine on
macOS 26.4. Throughput-wise this means large reads are ~free; small reads
are dominated by IPC.

## Kernel-offloaded I/O (the FUSE_PASSTHROUGH analog, with a catch)

`FSVolumeKernelOffloadedIOOperations` exposes `blockmapFile` + `completeIO`.
You map a file's logical offsets to **physical extents on a block device**
using `FSExtentPacker`; the kernel then performs I/O against those extents
without further RPCs to your extension.

This is the only API in FSKit that actually removes your extension from the
read/write data path. It's only available when the volume is backed by an
`FSBlockDeviceResource` (extents reference offsets on a block device).
For path-URL projection filesystems there's no equivalent. There's no
FUSE-style fd-passthrough primitive on macOS today.

## Mount mechanics

```
sudo mount -F -t <FSShortName> <resource> <mountpoint>
```

`mount` looks up the FSKit module by `FSShortName`, asks `fskitd` to launch
the extension, calls `probeResource` then `loadResource`, then `activate`.
The kernel keeps the volume alive until `umount` triggers `deactivate`.

The `Info.plist` `EXAppExtensionAttributes` block declares the FSKit module
to ExtensionKit. Key entries:

- `EXExtensionPointIdentifier = com.apple.fskit.fsmodule`
- `FSShortName` — the `-t` argument to `mount`.
- `FSPersonalities` — keyed dict of personality entries, each with at least
  `FSfileObjectsAreCaseSensitive`. Empty `{}` is allowed.
- `FSSupports{Block,PathURL,GenericURL,Server}Resources` — which resource
  type(s) this module accepts.
- `FSRequiresSecurityScopedPathURLResources` — whether the path URL needs
  `startAccessingSecurityScopedResource`.

## Performance findings (path-URL projection FS)

Measured on macOS 26.4.1, M-series, with `hyperfine`. See
`scripts/bench.sh` and `gotchas.md` for the workloads. Each row in the
optimization table represents adding one change on top of the row above.

### Per-RPC cost

Roughly **70 μs per kernel→extension RPC** on this hardware. This is the
floor; nothing in the API surface lets you go below "one RPC per kernel call
into the extension."

### The kernel caches aggressively, and the remaining slowdown isn't RPC tax

Once we instrumented the extension with per-method op counters (a
`__counters` virtual file inside the mount that returns current totals when
read), the actual RPC volume during a 4-benchmark run was wildly lower than
predicted from the workload:

| RPC | Count |
|---|---|
| `attributes` | 4146 |
| `lookupItem` | 4025 |
| `read` | 2106 |
| `enumerateDirectory` | 232 |
| `activate` | 1 |

For comparison, the workload nominally does on the order of **100,000 file
accesses** (4 benches × 13 iterations × 2000 files). The kernel
page-cached everything after the first iteration — subsequent iterations of
each `hyperfine` benchmark hardly RPC the extension at all.

So the remaining slowdown vs direct APFS (1.4× stat, 2.4× many-small,
2.0× full-tree) **isn't from RPC count**. At ~70 μs × 10K RPCs = ~700 ms
of RPC overhead total, but the actual gap between weldfs and direct
across the whole bench is on the order of 2–3 seconds. The extra time
must be coming from kernel-side overhead in the FSKit VFS layer itself —
data structure manipulation, locking, and bookkeeping that's heavier for
FSKit-mounted volumes than for native APFS, even when no RPC is needed.

Practical consequence: **further optimization on the extension side has
near-zero return** for cached workloads. The remaining cost is in macOS's
FSKit implementation in the kernel, and it's not user-tunable.

### Per-syscall comparison: weldfs `stat64` is *faster* than APFS

Profiled with `xctrace` (System Trace, all processes, kernel callstacks)
running a flat Python `os.stat()` loop against the same 20,000-file set,
once direct on APFS and once through a weldfs mount. Filtered to the
python3 worker thread:

|                       | DIRECT (APFS) | WELDFS    | Δ      |
|-----------------------|---------------|-----------|--------|
| `stat64` count (10 s) | 1,031,462     | 1,165,326 | +13%   |
| total syscall time    | 1917 ms       | 1550 ms   | −367 ms |
| **avg per `stat64`**  | **1.86 µs**   | **1.33 µs** | **−28%** |

In a flat stat-by-known-path workload, weldfs is faster per syscall than
direct APFS. weldfs's children dictionary is an O(1) Swift hash lookup
against in-memory state already cached in the kernel; APFS has to walk
its on-disk B-tree (cached but still more layered) for a 20k-entry
directory. weldfs is essentially behaving as an in-memory FS for stat
purposes here.

So where does the bench's 1.4× stat-traversal slowdown come from? Not
from `stat64` — the syscall itself is faster on weldfs. The remaining
candidates:

- `getdirentries64` / our `enumerateDirectory` — the bench's `find` walks
  the tree, which our profile pre-built outside the trace window. The
  RPC and namei work for directory enumeration is where FSKit pays a
  cost APFS doesn't.
- `opendir`/`closedir` per subdirectory.
- Process fork/exec overhead for `find`, `xargs`, `stat` (the binary).
  When we cycled tight `find | xargs stat` loops earlier, runningboardd
  + logd dominated 99% of CPU, indicating the kernel's process-startup
  bookkeeping had different costs.

This is the resolution to "where does the FSKit slowdown live": **not
in the steady-state syscall hot path, but in directory enumeration and
process-startup paths around it.**

For uncached workloads (cold page cache, e.g., across reboots), the
per-RPC cost we measured earlier (60–90 μs/RPC) does dominate, and the
extension-side optimizations matter — `isOpenCloseInhibited` saved 4× on
many-small-files in the cold case before kernel caching had populated.

### Cold cache: the slowdown ratio actually shrinks

Re-running the bench with `hyperfine --prepare 'sudo purge'` between every
iteration (drops the unified buffer cache):

| Workload | Direct (cold) | weldfs (cold) | Slowdown (cold) | Slowdown (warm) |
|---|---|---|---|---|
| Sequential 100 MiB | 119 ms | 147 ms | 1.23× | 1.05× |
| Many small (2000×4K) | 437 ms | 648 ms | **1.48×** | 2.46× |
| Stat traversal | 3.14 s | 4.25 s | 1.36× | 1.39× |
| Full tree read | 500 ms | 659 ms | **1.32×** | 2.05× |

Counterintuitively, cold cache *reduces* the slowdown ratio for read-heavy
workloads. In warm mode direct APFS gets an enormous kernel-cache boost
(many-small drops 12× warm vs cold). FSKit volumes get less benefit from
kernel caching, so when caching is removed from both sides, the
absolute-cost gap shrinks relative to total time.

RPC counts in cold mode are ~10× higher than warm:

| RPC | Cold | Warm | Ratio |
|---|---|---|---|
| `attributes` | 25,308 | 4,146 | 6.1× |
| `read` | 23,277 | 2,106 | 11.0× |
| `lookupItem` | 4,025 | 4,025 | **1.0× (unchanged)** |
| `enumerateDirectory` | 163 | 232 | 0.7× |

**`sudo purge` does not flush the kernel name cache.** Only the data
buffer cache and attribute cache get dropped. The vnode/path-resolution
cache (`namei` / `vfs_cache`) survives. So lookups that produced a vnode
once stay resolved across cache flushes.

Math check on the cold many-small case: 23,277 reads × 70 μs ≈ 1.6 s of
pure RPC overhead across the whole bench. Total weldfs cold time is
~5.7 s. So **~28% of cold weldfs time is XPC tax**; ~72% is the actual
I/O hitting disk (which both filesystems pay).

### What each optimization is worth

All numbers below are `hyperfine --warmup 3 --runs 10`, weldfs vs direct
(APFS). Times are mean ± noise. Slowdown is the ratio in the direction of
the slower side.

#### Bench A: Sequential read (100 MiB)

| Configuration | direct | weldfs | Slowdown |
|---|---|---|---|
| Cached fd + no hot-path logging | 11.0 ms | 14.7 ms | 1.40× |
| Cached fd + no logging + `enumerateDirectory` cookie/sort fix | 10.6 ms | 11.3 ms | 1.07× |
| + `isOpenCloseInhibited = true` | 10.7 ms | 10.7 ms | 1.00× |
| + `requestedMountOptions = .readOnly` | 11.0 ms | 10.7 ms | 1.03× (parity) |
| + capability flags (no hardlinks, fastStatFS, no root times) | 10.9 ms | 11.0 ms | 1.01× (parity) |

#### Bench B: Many small files (2000 × 4 KiB)

| Configuration | direct | weldfs | Slowdown | Per-file cost |
|---|---|---|---|---|
| Cookie-aware `enumerateDirectory` (functional) | 37.4 ms | 577 ms | 15.4× | 288 μs |
| Cached fd + no hot-path logging | 37.4 ms | 378 ms | 10.1× | 184 μs |
| + `isOpenCloseInhibited = true` | 37.3 ms | **91.6 ms** | **2.46×** | **46 μs** |
| + `requestedMountOptions = .readOnly` | 38.4 ms | 94.3 ms | 2.46× | 47 μs |
| + capability flags (no hardlinks, fastStatFS, no root times) | 37.5 ms | 92.2 ms | 2.46× | 46 μs |

#### Bench C: Stat traversal (find -type f -print0 \| xargs -0 stat)

| Configuration | direct | weldfs | Slowdown |
|---|---|---|---|
| Cached fd + no hot-path logging | 3.08 s | 4.38 s | 1.42× |
| + `enumerateDirectory` cookie/sort fix | 3.11 s | 4.29 s | 1.38× |
| + `isOpenCloseInhibited = true` | 3.16 s | 4.38 s | 1.39× |
| + `requestedMountOptions = .readOnly` | 3.22 s | 4.37 s | 1.36× |
| + capability flags (no hardlinks, fastStatFS, no root times) | 3.10 s | 4.31 s | 1.39× |

#### Bench D: Full tree read (find + cat all)

| Configuration | direct | weldfs | Slowdown |
|---|---|---|---|
| Cached fd + no hot-path logging | 47 ms | 605 ms | 11.8× |
| + `enumerateDirectory` cookie/sort fix | 51 ms | 377 ms | 8.0× |
| + `isOpenCloseInhibited = true` | 51 ms | **104 ms** | **2.05×** |
| + `requestedMountOptions = .readOnly` | 49 ms | 101 ms | 2.08× |
| + capability flags (no hardlinks, fastStatFS, no root times) | 52 ms | 102 ms | 1.99× |

### What moved what

- **`enumerateDirectory` cookie/sort fix**: was a correctness bug
  (infinite loop on dirs > 1 packer-buffer); after the fix, weldfs
  actually completes the bench. Counts as the "no longer broken" baseline.
- **Cached fd + no hot-path logging**: ~36% improvement on Bench B; saved
  the syscall churn from `open(2)`/`close(2)` per file. Per-file cost
  dropped from 288 μs to 184 μs.
- **`isOpenCloseInhibited = true`**: ~4× improvement on Bench B and D.
  Removed two of three per-file RPCs (`openItem`+`closeItem`), leaving
  only `read`. Per-file cost dropped from 184 μs to 46 μs. Confirms the
  RPC floor is ~70 μs/call.
- **`requestedMountOptions = .readOnly`**: no measurable change on any
  bench. Our workloads don't write, so the disabled write paths weren't
  being hit. Still the right declarative signal to have set.
- **Capability flags** (`supportsHardLinks=false`, `supportsFastStatFS=true`,
  `doesNotSupportRootTimes=true`): also no measurable change. The kernel
  evidently isn't speculatively probing for these on a read workload.
  Setting them is correctness/clarity, not perf.

Stat-only traversal sits at ~1.4× and barely moves. The 575 μs/file
overhead vs direct can't be just the one `attributes()` RPC at 70 μs;
there are likely multiple lookups + attribute calls per `stat()` call.
Need to instrument or add `enumerateDirectory(attributes:)` analysis.

## Knobs we have exhausted (confirmed not measurable)

We tried each of the following one at a time, both warm and cold cache, and
saw no change beyond noise:

- `requestedMountOptions = .readOnly` — kernel doesn't speculatively call
  write paths anyway on read workloads.
- `supportsFastStatFS = true`, `doesNotSupportRootTimes = true`,
  `supportsHardLinks = false` — capability hints didn't shift any RPC count.
- `FSVolume.AccessCheckOperations` conformance with
  `isAccessCheckInhibited = true` — no measurable effect.
- Always providing attributes in `enumerateDirectory` (instead of only when
  the kernel asks) — no measurable effect.
- `mmap`-cached backing files with `memcpy` into the FSKit buffer instead
  of `pread` — no measurable effect. The data path cost is the same; the
  bottleneck is the per-RPC kernel↔extension hop, not the data copy
  inside the extension.

Conclusion: extension-side optimization for a path-URL projection FS is
fully exhausted with: cached fd + `isOpenCloseInhibited` + stable
cookie-aware `enumerateDirectory` + hot-path-logger-free + correct
app-sandbox entitlements. The remaining 1.3–2.5× slowdown comes from
macOS's FSKit kernel-side VFS layer and is not user-tunable from inside
the extension.

## Open questions

- We hand the kernel attributes in the `packEntry` call from
  `enumerateDirectory`, but profiling shows the kernel still issues
  separate `attributes()` RPCs afterward in some workloads. There's no
  documented capability flag to declare "the attributes I gave you in
  enumerate are authoritative — don't ask again."
- Is there a way to declare the volume as "in-RAM, no locality" so the
  kernel skips standard caching/locking that assumes spinning rust?
- Where exactly does FSKit's per-syscall kernel-side overhead come from?
  We can see it exists (`stat()`-heavy benches show 1.4× slowdown despite
  the syscall itself being faster than APFS), but without kernel symbols
  we can't pin it to a specific code path. Probably in the FSKit VFS
  vnode-ops dispatcher.

## Methodology / how the numbers were obtained

- `scripts/bench.sh` — `hyperfine` macrobench comparing direct APFS reads
  against the same files projected through weldfs. Four workloads:
  sequential-read, many-small-files, stat-traversal, full-tree-read.
  `COLD=1 scripts/bench.sh` adds `--prepare 'sudo purge'` between runs.
- `scripts/profile.sh` — runs a Python `os.stat()` (or `os.read()`)
  loop against the weldfs mount under `xctrace` System Trace, all
  processes, with kernel callstacks. Drops a `.trace` for analysis.
- `scripts/compare.sh` — same Python loop, run twice (once direct on the
  source dir, once through weldfs), with per-syscall aggregation
  comparing `stat64` counts and average durations between the two
  filesystem types.
- `scripts/_aggregate_syscalls.py` — extracts syscall durations from a
  trace, filtered to the python3 worker thread.
- The `__counters` virtual file inside the mount returns op counts on
  read (kernel-cache-defeated by bumping `mtime` in `attributes()`), used
  as a backdoor for inspecting RPC volume from `bench.sh`.

## Things explicitly missing from FSKit (vs. FUSE)

- **No fd-passthrough primitive.** No way to delegate read/write to a
  pre-opened file descriptor. The kernel always RPCs into the extension
  for `read`/`write` unless you implement
  `FSVolumeKernelOffloadedIOOperations`, which requires a block device.
- **No splice / zero-copy.** The XPC channel copies bytes out of the
  extension's `FSMutableFileDataBuffer` into kernel memory.
- **No batched RPCs.** One open/read/close turns into three separate XPC
  hops; there's no protocol to bundle them.
- **No async completion-style I/O without extents.** Fire-and-forget
  reads/writes only exist via the block-device-extent path.
