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

End-to-end measurements with `hyperfine` comparing direct filesystem reads
against the same files projected through this FSKit module. Code is
optimized to the floor: backing fds cached for the volume's lifetime, no
hot-path logging, manifest pre-stat'd. See `scripts/bench.sh`.

| Workload                    | Direct  | weldfs  | Slowdown |
|-----------------------------|---------|---------|----------|
| Sequential read (100 MiB)   | 11 ms   | 12 ms   | 1.05×    |
| Many small files (2000×4K)  | 37 ms   | 378 ms  | 10.1×    |
| Stat traversal              | 3.11 s  | 4.29 s  | 1.38×    |
| Full tree read              | 52 ms   | 423 ms  | 8.0×     |

Per-file cost breakdown for the many-small-files case: 378 ms / 2000 ≈
**184 μs per file**. The actual `pread` of 4 KiB out of buffer cache is ~1 μs,
so ~183 μs/file is pure XPC RPC. With three round-trips per file
(`openItem`+`read`+`closeItem`), that works out to **~60 μs per kernel→
extension hop**. This is the structural floor on the current API; the only
way to go lower is to remove kernel→extension hops, which requires an
fd-passthrough primitive analogous to Linux's `FUSE_PASSTHROUGH`.

## SourceKit

- "Cannot find 'X' in scope" errors that disappear after building are
  SourceKit indexing artifacts across multi-file modules. The actual compile
  is fine.
