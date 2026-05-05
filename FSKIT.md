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

## Knobs we haven't exhausted

- `requestedMountOptions = .readOnly` (next)
- `supportsFastStatFS` (free if the kernel actually caches)
- `accessCheckInhibited` (if we conform to access checking)
- Conform to `FSVolumeItemDeactivation` and use `itemDeactivationPolicy` to
  keep frequently-accessed items hot
- Investigate whether the kernel issues bulk-stat-style RPCs we could opt
  into and answer in one shot

## Open questions

- What's the exact RPC pattern the kernel uses for `find -type f -print0 |
  xargs -0 stat`? Per stat we see 2× the direct cost; that's higher than
  one RPC's worth — possibly multiple lookupItem + attributes round-trips
  per `stat()`.
- Can `enumerateDirectory` return attributes in-band (via the `attributes`
  param) to skip subsequent `attributes()` round-trips? We pass them when
  the caller asks; need to check whether that path actually elides the
  per-item RPC.
- Is there a way to declare the volume as "in-RAM, no locality" so the
  kernel skips standard caching/locking that assumes spinning rust?

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
