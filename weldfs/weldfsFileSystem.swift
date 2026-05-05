import Foundation
import FSKit
import os

// MARK: - File system entry point

@objc
class weldfsFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
    private let logger = Logger(subsystem: "weldfs", category: "FS")

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        logger.debug("unloadResource: \(resource, privacy: .public)")
        if let pathResource = resource as? FSPathURLResource {
            pathResource.url.stopAccessingSecurityScopedResource()
        }
        reply(nil)
    }

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        logger.debug("probeResource: \(resource, privacy: .public)")
        replyHandler(
            FSProbeResult.usable(
                name: "weldfs",
                containerID: FSContainerIdentifier(uuid: Constants.containerIdentifier)
            ),
            nil
        )
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        logger.debug("loadResource: \(resource, privacy: .public)")
        guard let pathResource = resource as? FSPathURLResource else {
            replyHandler(nil, fs_errorForPOSIXError(POSIXError.EINVAL.rawValue))
            return
        }
        guard pathResource.url.startAccessingSecurityScopedResource() else {
            logger.error("startAccessingSecurityScopedResource failed for \(pathResource.url.path, privacy: .public)")
            replyHandler(nil, fs_errorForPOSIXError(POSIXError.EACCES.rawValue))
            return
        }
        containerStatus = .ready
        replyHandler(WeldFSVolume(resource: pathResource), nil)
    }
}

// MARK: - In-memory inode

final class WeldFSItem: FSItem {
    private static var nextID: UInt64 = FSItem.Identifier.rootDirectory.rawValue + 1
    static func getNextID() -> UInt64 {
        let current = nextID
        nextID += 1
        return current
    }

    let name: FSFileName
    let id = WeldFSItem.getNextID()

    var attributes = FSItem.Attributes()
    var xattrs: [FSFileName: Data] = [:]
    var data: Data?
    var linkname: FSFileName?

    var backingPath: String?
    /// If set, `read` calls this to get fresh bytes instead of using `data`.
    /// Used for virtual debug files like __counters.
    var dataProvider: (() -> Data)?
    private(set) var fileDescriptor: Int32 = -1
    private(set) var mmapPtr: UnsafeMutableRawPointer?
    private(set) var mmapLen: Int = 0
    private let openLock = NSLock()

    private static let itemLogger = Logger(subsystem: "weldfs", category: "Item")

    private(set) var children: [String: WeldFSItem] = [:]

    init(name: FSFileName) {
        self.name = name
        attributes.fileID = FSItem.Identifier(rawValue: id) ?? .invalid
        attributes.size = 0
        attributes.allocSize = 0
        attributes.flags = 0

        var ts = timespec()
        timespec_get(&ts, TIME_UTC)
        attributes.addedTime = ts
        attributes.birthTime = ts
        attributes.changeTime = ts
        attributes.modifyTime = ts
    }

    func addItem(_ item: WeldFSItem) {
        item.attributes.parentID = self.attributes.fileID
        children[item.name.string!] = item
    }

    func removeItem(_ item: WeldFSItem) {
        children[item.name.string!] = nil
    }

    /// Open the backing fd if not already open. Cached for the lifetime of
    /// the volume; never closed by closeBackingFile. The fd is reclaimed
    /// either by `releaseBackingFile()` (called at volume teardown) or when
    /// the extension process exits on unmount.
    func openBackingFile() throws {
        openLock.lock()
        defer { openLock.unlock() }
        if fileDescriptor >= 0 { return }
        guard let backingPath else { return }
        let fd = open(backingPath, O_RDONLY)
        if fd < 0 {
            let err = errno
            WeldFSItem.itemLogger.error("open(\(backingPath, privacy: .public)) failed: errno=\(err) (\(String(cString: strerror(err)), privacy: .public))")
            throw fs_errorForPOSIXError(err)
        }
        fileDescriptor = fd
        // Map the whole file once; subsequent reads memcpy out of it instead
        // of going through pread(2). Saves the kernel→user copy that pread
        // does, leaving only one user-space memcpy into the FSKit buffer.
        let size = Int(attributes.size)
        if size > 0 {
            let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
            if p != MAP_FAILED {
                mmapPtr = p
                mmapLen = size
            }
        }
    }

    /// No-op: we keep the fd + mapping until the volume is torn down. See
    /// `releaseBackingFile()` for actual cleanup.
    func closeBackingFile() {}

    func releaseBackingFile() {
        openLock.lock()
        defer { openLock.unlock() }
        if let p = mmapPtr, mmapLen > 0 {
            munmap(p, mmapLen)
            mmapPtr = nil
            mmapLen = 0
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

// MARK: - Volume

final class OpCounters {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func bump(_ key: String) {
        lock.lock(); counts[key, default: 0] += 1; lock.unlock()
    }
    func snapshot() -> [(String, Int)] {
        lock.lock(); defer { lock.unlock() }
        return counts.sorted { $0.value > $1.value }
    }
    func snapshotAndReset() -> [(String, Int)] {
        lock.lock(); defer { lock.unlock() }
        let out = counts.sorted { $0.value > $1.value }
        counts.removeAll()
        return out
    }
    func reset() {
        lock.lock(); counts.removeAll(); lock.unlock()
    }
    func renderText() -> Data {
        let snap = snapshot()
        var lines = ""
        for (name, count) in snap {
            lines += "\(name)\t\(count)\n"
        }
        return Data(lines.utf8)
    }
}

final class WeldFSVolume: FSVolume {
    let resource: FSPathURLResource
    let logger = Logger(subsystem: "weldfs", category: "Volume")
    let counters = OpCounters()

    let root: WeldFSItem = {
        let item = WeldFSItem(name: FSFileName(string: "/"))
        item.attributes.parentID = .parentOfRoot
        item.attributes.fileID = .rootDirectory
        item.attributes.uid = 0
        item.attributes.gid = 0
        item.attributes.linkCount = 1
        item.attributes.type = .directory
        item.attributes.mode = UInt32(S_IFDIR | 0b111_000_000)
        item.attributes.allocSize = 1
        item.attributes.size = 1
        return item
    }()

    let version: WeldFSItem = {
        let item = WeldFSItem(name: FSFileName(string: "weldfs_version"))
        item.attributes.type = .file
        item.data = "0.0.0".data(using: .utf8)
        item.attributes.size = 5
        item.attributes.allocSize = 5
        item.attributes.mode = UInt32(S_IFREG | 0b111_000_000)
        return item
    }()

    init(resource: FSPathURLResource) {
        self.resource = resource
        super.init(
            volumeID: FSVolume.Identifier(uuid: Constants.volumeIdentifier),
            volumeName: FSFileName(string: "weldfs")
        )
        self.root.addItem(self.version)

        // Virtual debug file: `cat /mnt/__counters` returns current op counts.
        let countersItem = WeldFSItem(name: FSFileName(string: "__counters"))
        countersItem.attributes.type = .file
        countersItem.attributes.mode = UInt32(S_IFREG | 0b100_100_100)
        countersItem.attributes.size = 0
        countersItem.attributes.allocSize = 0
        countersItem.dataProvider = { [weak self] in
            self?.counters.renderText() ?? Data()
        }
        self.root.addItem(countersItem)
    }
}

extension WeldFSVolume: FSVolume.PathConfOperations {
    var maximumNameLength: Int { -1 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumLinkCount: Int { -1 }
    var maximumXattrSize: Int { Int.max }
    var maximumFileSize: UInt64 { UInt64.max }
}

// MARK: - Helpers

private func mergeAttributes(_ existing: FSItem.Attributes, request: FSItem.SetAttributesRequest) {
    if request.isValid(.uid) { existing.uid = request.uid }
    if request.isValid(.gid) { existing.gid = request.gid }
    if request.isValid(.type) { existing.type = request.type }
    if request.isValid(.mode) { existing.mode = request.mode }
    if request.isValid(.linkCount) { existing.linkCount = request.linkCount }
    if request.isValid(.flags) { existing.flags = request.flags }
    if request.isValid(.size) { existing.size = request.size }
    if request.isValid(.allocSize) { existing.allocSize = request.allocSize }
    if request.isValid(.fileID) { existing.fileID = request.fileID }
    if request.isValid(.parentID) { existing.parentID = request.parentID }

    var ts = timespec()
    if request.isValid(.accessTime) { request.accessTime = ts; existing.accessTime = ts }
    if request.isValid(.changeTime) { request.changeTime = ts; existing.changeTime = ts }
    if request.isValid(.modifyTime) { request.modifyTime = ts; existing.modifyTime = ts }
    if request.isValid(.addedTime) { request.addedTime = ts; existing.addedTime = ts }
    if request.isValid(.birthTime) { request.birthTime = ts; existing.birthTime = ts }
    if request.isValid(.backupTime) { request.backupTime = ts; existing.backupTime = ts }
}

// MARK: - Volume operations

extension WeldFSVolume: FSVolume.Operations {
    // Mark the volume read-only so the kernel skips write-path RPCs entirely.
    @objc var requestedMountOptions: FSVolume.MountOptions { .readOnly }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsHardLinks = false           // we don't; we throw EIO from createLink
        c.supportsSymbolicLinks = true
        c.supportsPersistentObjectIDs = true
        c.doesNotSupportVolumeSizes = true
        c.supportsHiddenFiles = true
        c.supports64BitObjectIDs = true
        c.supportsFastStatFS = true           // statfs is cheap for us, hint the kernel
        c.doesNotSupportRootTimes = true      // we don't track meaningful root timestamps
        c.caseFormat = .insensitiveCasePreserving
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "weldfs")
        result.blockSize = 1024000
        result.ioSize = 1024000
        result.totalBlocks = 1024000
        result.availableBlocks = 1024000
        result.freeBlocks = 1024000
        result.totalFiles = 1024000
        result.freeFiles = 1024000
        return result
    }

    struct FileInfo: Codable {
        let path: String
        let root: String?
        let dir: Bool?
    }

    func parseJSON(_ data: Data) -> [FileInfo]? {
        try? JSONDecoder().decode([FileInfo].self, from: data)
    }

    @discardableResult
    func addParents(components: [String.SubSequence]) -> WeldFSItem {
        var parent = root
        for component in components {
            let key = String(component)
            if let existing = parent.children[key] {
                parent = existing
            } else {
                let child = WeldFSItem(name: FSFileName(string: key))
                child.attributes.parentID = parent.attributes.fileID
                child.attributes.type = .directory
                child.attributes.mode = 0o755
                child.attributes.gid = 20
                child.attributes.uid = 501
                parent.addItem(child)
                parent = child
            }
        }
        return parent
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        counters.bump("activate")
        let manifestURL = resource.url
        logger.info("activate from \(manifestURL.path, privacy: .public)")

        let data = try Data(contentsOf: manifestURL)
        guard let entries = parseJSON(data) else {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        for entry in entries {
            var components = entry.path.split(separator: "/")
            if entry.dir ?? false {
                addParents(components: components)
                continue
            }
            guard let backing = entry.root else {
                logger.error("file entry missing root: \(entry.path, privacy: .public)")
                continue
            }
            var st = stat()
            guard stat(backing, &st) == 0 else {
                logger.error("stat failed for \(backing, privacy: .public): errno=\(errno)")
                continue
            }
            let name = components.popLast()!
            let parent = addParents(components: components)
            let child = WeldFSItem(name: FSFileName(string: String(name)))
            child.backingPath = backing
            child.attributes.type = .file
            child.attributes.mode = UInt32(S_IFREG | 0b100_100_100)
            child.attributes.size = UInt64(st.st_size)
            child.attributes.allocSize = UInt64(st.st_blocks) * 512
            parent.addItem(child)
        }
        return root
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        // Walk the tree and close every cached fd.
        var stack: [WeldFSItem] = [root]
        while let item = stack.popLast() {
            item.releaseBackingFile()
            stack.append(contentsOf: item.children.values)
        }
    }

    func mount(options: FSTaskOptions) async throws {
        logger.info("mount \(options.taskOptions)")
    }

    func unmount() async {
        // umount(8) lands here. Dump op counts before any other teardown so we
        // can see how many RPCs the kernel made between mount and unmount.
        let snapshot = counters.snapshotAndReset()
        logger.notice("=== weldfs op counts ===")
        for (name, count) in snapshot {
            logger.notice("  \(name, privacy: .public): \(count)")
        }
    }

    func synchronize(flags: FSSyncFlags) async throws {}

    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        counters.bump("attributes")
        guard let item = item as? WeldFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        // Virtual files: refresh size and bump mtime so the kernel buffer
        // cache (keyed by size+mtime) treats every stat as a new revision.
        if let provider = item.dataProvider {
            let size = UInt64(provider().count)
            item.attributes.size = size
            item.attributes.allocSize = size
            var ts = timespec()
            timespec_get(&ts, TIME_UTC)
            item.attributes.modifyTime = ts
            item.attributes.changeTime = ts
        }
        return item.attributes
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        counters.bump("setAttributes")
        guard let item = item as? WeldFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        mergeAttributes(item.attributes, request: newAttributes)
        return item.attributes
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        counters.bump("lookupItem")
        guard let directory = directory as? WeldFSItem else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        if let item = directory.children[name.string!] {
            return (item, name)
        }
        throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
    }

    func reclaimItem(_ item: FSItem) async throws { counters.bump("reclaimItem") }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        counters.bump("readSymbolicLink")
        guard let item = item as? WeldFSItem, item.attributes.type == .symlink, let link = item.linkname else {
            throw fs_errorForPOSIXError(POSIXError.ENOLINK.rawValue)
        }
        return link
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        guard let directory = directory as? WeldFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        let item = WeldFSItem(name: name)
        mergeAttributes(item.attributes, request: newAttributes)
        item.attributes.parentID = directory.attributes.fileID
        item.attributes.type = type
        directory.addItem(item)
        return (item, name)
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        guard let directory = directory as? WeldFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        let item = WeldFSItem(name: name)
        mergeAttributes(item.attributes, request: newAttributes)
        item.attributes.parentID = directory.attributes.fileID
        item.attributes.type = .symlink
        item.attributes.size = UInt64(contents.data.count)
        item.linkname = contents
        directory.addItem(item)
        return (item, contents)
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        guard let item = item as? WeldFSItem, let directory = directory as? WeldFSItem else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        directory.removeItem(item)
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) async throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        counters.bump("enumerateDirectory")
        guard let directory = directory as? WeldFSItem else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        // Stable order across calls so cookie-based resume is meaningful.
        let entries = directory.children.keys.sorted().compactMap { directory.children[$0] }
        var idx = Int(cookie.rawValue)
        while idx < entries.count {
            let item = entries[idx]
            // nextCookie is what the kernel sends back on the next call.
            let accepted = packer.packEntry(
                name: item.name,
                itemType: item.attributes.type,
                itemID: item.attributes.fileID,
                nextCookie: FSDirectoryCookie(UInt64(idx + 1)),
                // Always provide attributes; some callers may use them to
                // skip subsequent attributes() RPCs even when not requested.
                attributes: item.attributes
            )
            // Buffer full: kernel will re-call with the last accepted cookie.
            if !accepted { break }
            idx += 1
        }
        return FSDirectoryVerifier(0)
    }
}

extension WeldFSVolume: FSVolume.OpenCloseOperations {
    // Tell the kernel not to call openItem/closeItem at all. We don't track
    // per-handle state (fds are cached for the volume lifetime), so the
    // kernel's open/close round-trips are pure overhead for us.
    @objc var isOpenCloseInhibited: Bool { true }

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        counters.bump("openItem")
        guard let item = item as? WeldFSItem, item.backingPath != nil else { return }
        try item.openBackingFile()
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        counters.bump("closeItem")
        // No-op: fd stays cached for the lifetime of the volume.
    }
}

extension WeldFSVolume: FSVolume.ReadWriteOperations {
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        counters.bump("read")
        guard let item = item as? WeldFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }

        // Virtual files (e.g., __counters) compute fresh bytes on each read.
        let inMemory: Data? = item.dataProvider?() ?? item.data
        if let data = inMemory {
            let start = Int(offset)
            let available = max(0, data.count - start)
            let n = min(min(length, buffer.length), available)
            guard n > 0 else { return 0 }
            data.withUnsafeBytes { src in
                _ = buffer.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress, src.baseAddress!.advanced(by: start), n)
                }
            }
            return n
        }

        guard item.backingPath != nil else { return 0 }

        if item.fileDescriptor < 0 {
            try item.openBackingFile()
        }

        // Prefer mmap-cached data: skip the pread syscall and one of the data
        // copies. Fall back to pread if mmap failed or the file is empty.
        if let mmap = item.mmapPtr {
            let start = Int(offset)
            let available = max(0, item.mmapLen - start)
            let n = min(min(length, buffer.length), available)
            guard n > 0 else { return 0 }
            _ = buffer.withUnsafeMutableBytes { dst in
                memcpy(dst.baseAddress, mmap.advanced(by: start), n)
            }
            return n
        }

        let requested = min(length, buffer.length)
        let fd = item.fileDescriptor
        let n = buffer.withUnsafeMutableBytes { dst -> Int in
            pread(fd, dst.baseAddress, requested, offset)
        }
        if n < 0 {
            let err = errno
            logger.error("pread(fd=\(fd), len=\(requested), off=\(offset)) failed errno=\(err) (\(String(cString: strerror(err)), privacy: .public))")
            throw fs_errorForPOSIXError(err)
        }
        return n
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        guard let item = item as? WeldFSItem else { return 0 }
        item.data = contents
        item.attributes.size = UInt64(contents.count)
        item.attributes.allocSize = UInt64(contents.count)
        return contents.count
    }
}

extension WeldFSVolume: FSVolume.AccessCheckOperations {
    // Conform to advertise capability, then disable so the kernel skips
    // calling our checkAccess at all. Default-allow falls through.
    @objc var isAccessCheckInhibited: Bool { true }

    func checkAccess(to item: FSItem, requestedAccess: FSVolume.AccessMask) async throws -> Bool {
        return true
    }
}
