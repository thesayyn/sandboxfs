//
//  SandboxFSVolume.swift
//  sandbox
//
//  Created by Sahin Yort on 2025-04-16.
//

import Foundation
import FSKit
import os

private func mergeAttributes(_ existing: FSItem.Attributes, request: FSItem.SetAttributesRequest) {
        if request.isValid(FSItem.Attribute.uid) {
            existing.uid = request.uid
        }
        
        if request.isValid(FSItem.Attribute.gid) {
            existing.gid = request.gid
        }
        
        if request.isValid(FSItem.Attribute.type) {
            existing.type = request.type
        }
        
        if request.isValid(FSItem.Attribute.mode) {
            existing.mode = request.mode
        }
        
        if request.isValid(FSItem.Attribute.linkCount) {
            existing.linkCount = request.linkCount
        }
        
        if request.isValid(FSItem.Attribute.flags) {
            existing.flags = request.flags
        }
        
        if request.isValid(FSItem.Attribute.size) {
            existing.size = request.size
        }
        
        if request.isValid(FSItem.Attribute.allocSize) {
            existing.allocSize = request.allocSize
        }
        
        if request.isValid(FSItem.Attribute.fileID) {
            existing.fileID = request.fileID
        }

        if request.isValid(FSItem.Attribute.parentID) {
            existing.parentID = request.parentID
        }

        if request.isValid(FSItem.Attribute.accessTime) {
            let timespec = timespec()
            request.accessTime = timespec
            existing.accessTime = timespec
        }
        
        if request.isValid(FSItem.Attribute.changeTime) {
            let timespec = timespec()
            request.changeTime = timespec
            existing.changeTime = timespec
        }
        
        if request.isValid(FSItem.Attribute.modifyTime) {
            let timespec = timespec()
            request.modifyTime = timespec
            existing.modifyTime = timespec
        }
        
        if request.isValid(FSItem.Attribute.addedTime) {
            let timespec = timespec()
            request.addedTime = timespec
            existing.addedTime = timespec
        }
        
        if request.isValid(FSItem.Attribute.birthTime) {
            let timespec = timespec()
            request.birthTime = timespec
            existing.birthTime = timespec
        }
        
        if request.isValid(FSItem.Attribute.backupTime) {
            let timespec = timespec()
            request.backupTime = timespec
            existing.backupTime = timespec
        }
    }


extension SandboxFSVolume: FSVolume.Operations {
        
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        logger.info("supportedVolumeCapabilities")
               
       let capabilities = FSVolume.SupportedCapabilities()
       capabilities.supportsHardLinks = true
       capabilities.supportsSymbolicLinks = true
       capabilities.supportsPersistentObjectIDs = true
       capabilities.doesNotSupportVolumeSizes = true
       capabilities.supportsHiddenFiles = true
       capabilities.supports64BitObjectIDs = true
       capabilities.caseFormat = .insensitiveCasePreserving
       return capabilities
    }
    
    var volumeStatistics: FSStatFSResult {
        logger.info("volumeStatistics")
        
        let result = FSStatFSResult(fileSystemTypeName: "sandboxfs")
               
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
    
    func parseJSON(jsonString: String) -> [FileInfo]? {
        // Convert JSON string to Data
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("Failed to convert JSON string to Data")
            return nil
        }
        
        // Create JSON Decoder
        let decoder = JSONDecoder()
        
        do {
            // Decode JSON into array of FileInfo
            let fileInfos = try decoder.decode([FileInfo].self, from: jsonData)
            return fileInfos
        } catch {
            print("Error decoding JSON: \(error)")
            return nil
        }
    }
    
    func add_parents(components: [String.SubSequence]) -> SandboxFSItem {
        var parent: SandboxFSItem = root
        for (i, component) in components.enumerated() {
            if let has = parent.children[String(component)] {
                parent = has
            } else {
                let child = SandboxFSItem(name: FSFileName(string: String(component)))
                child.attributes.parentID = parent.attributes.fileID
                child.attributes.type = .directory
                child.attributes.mode = 493
                child.attributes.gid = 20
                child.attributes.uid = 501
                parent.addItem(child)
                parent = child
            }
        }
        return parent
    }
    
    func activate(options: FSTaskOptions) async throws -> FSItem {
        logger.info("activate \(options.taskOptions, privacy: .public)")
        
        var path: String?;
        
        for option in options.taskOptions {
            if !option.starts(with: "/Users/thesayyn") {
                continue
            }
            path = option
        }
            
        logger.info("parsing from \(path!, privacy: .public )")
        let jsonString = try String(contentsOfFile: path!, encoding: .utf8)
        
        logger.info("contents: \(jsonString, privacy: .public)")
            
        if let fileInfos = parseJSON(jsonString: jsonString) {
            for fileInfo in fileInfos {
                var components = fileInfo.path.split(separator: "/")
                
                if fileInfo.dir ?? false {
                    logger.info("dir \(fileInfo.path, privacy: .public)")
                    add_parents(components: components)
                } else {
                    let name = components.popLast()
                    let parent = add_parents(components: components)
                    
                    let child = SandboxFSItem(name: FSFileName(string: String(name!)))
                    
                    child.attributes.mode = UInt32(S_IFLNK | 0b111_000_000)
                    child.attributes.type = .symlink
                    child.attributes.flags = 0
                    child.linkname = FSFileName.init(string: fileInfo.root!)
                    child.attributes.size = UInt64(child.linkname!.data.count)
                    parent.addItem(child)
                    
                }
                
                logger.info("Dir: \(fileInfo.dir ?? false, privacy: .public)")
                logger.info("Path: \(fileInfo.path, privacy: .public)")
                logger.info("Root: \(fileInfo.root ?? "no root", privacy: .public)")
            }
        }
        
    
        
        return root
    }
    
    
    func deactivate(options: FSDeactivateOptions = []) async throws {
        logger.info("deactivate")
    }
    
    func mount(options: FSTaskOptions) async throws {
        logger.info("mount \(options.taskOptions)")
    }
    
    func unmount() async {
        logger.info("unmount")
    }
    

    func synchronize(flags: FSSyncFlags) async throws {
        logger.info("synchronize")
    }
    

    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        if let item = item as? SandboxFSItem {
            logger.info("getItemAttributes1: \(item.name.string!, privacy: .public)")
            return item.attributes
        } else {
            logger.info("getItemAttributes2: \(item), \(desiredAttributes)")
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
    }
    
    
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        logger.info("setItemAttributes: \(item), \(newAttributes)")
           if let item = item as? SandboxFSItem {
               mergeAttributes(item.attributes, request: newAttributes)
               return item.attributes
           } else {
               throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
           }
    }

    
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        guard let directory = directory as? SandboxFSItem else {
           throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        
        logger.info("lookupItem: \(name.string!, privacy: .public), \(directory.id)")
        
    
        if let item = directory.children[name.string!] {
           return (item, name)
        } else {
            logger.info("can not find \(name.string!, privacy: .public) in \(directory.id)")
           throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
    }
    

    func reclaimItem(_ item: FSItem) async throws {
        logger.info("reclaimItem: \(item)")
    }
    
    
    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        logger.info("readSymbolicLink: \(item)")
        guard let fsitem = item as? SandboxFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        if fsitem.attributes.type != .symlink {
            throw fs_errorForPOSIXError(POSIXError.ENOLINK.rawValue)
        }
        return fsitem.linkname!
    }
     

    
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        logger.info("createItem: \(String(describing: name.string)) - \(newAttributes.mode)")
        
        guard let directory = directory as? SandboxFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        
        let item = SandboxFSItem(name: name)
        mergeAttributes(item.attributes, request: newAttributes)
        item.attributes.parentID = directory.attributes.fileID
        item.attributes.type = type
        directory.addItem(item)
        
        return (item, name)
    }
    

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        logger.info("createSymbolicLink: \(name) \(newAttributes.flags, privacy: .public) \(contents.string!, privacy: .public)")
        
        guard let directory = directory as? SandboxFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        
        let item = SandboxFSItem(name: name)
        mergeAttributes(item.attributes, request: newAttributes)
        item.attributes.parentID = directory.attributes.fileID
        item.attributes.type = .symlink
        item.attributes.size = UInt64(contents.data.count)
        item.linkname = contents
        directory.addItem(item)
        return (item, contents)
    }
    

    
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        logger.info("createLink: \(name)")
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }
    

    
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        logger.info("remove: \(name)")
        if let item = item as? SandboxFSItem, let directory = directory as? SandboxFSItem {
            directory.removeItem(item)
        } else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
    }
    
    
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) async throws -> FSFileName {
        logger.info("rename: \(item)")
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }
    
    
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
       guard let directory = directory as? SandboxFSItem else {
           throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
       }
       
        logger.info("- enumerateDirectory - \(directory.name, privacy: .public)")
       
       for (idx, item) in directory.children.values.enumerated() {
           let isLast = (idx == directory.children.count - 1)
           
           let v = packer.packEntry(
               name: item.name,
               itemType: item.attributes.type,
               itemID: item.attributes.fileID,
               nextCookie: FSDirectoryCookie(UInt64(idx)),
               attributes: attributes != nil ? item.attributes : nil
               
           )
           
           logger.info("-- V: \(item.name.string!, privacy: .public)")
       }
        return FSDirectoryVerifier(0)
    }
}


extension SandboxFSVolume: FSVolume.OpenCloseOperations {
    
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        if let item = item as? SandboxFSItem {
            logger.info("open: \(item.name)")
        } else {
            logger.info("open: \(item)")
        }
    }
    
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        if let item = item as? SandboxFSItem {
            logger.info("close: \(item.name)")
        } else {
            logger.info("close: \(item)")
        }
    }
}


extension SandboxFSVolume: FSVolume.XattrOperations {

    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        logger.info("xattr: \(item) - \(name.string!, privacy: .public)")
        
        if let item = item as? SandboxFSItem {
            return item.xattrs[name] ?? Data()
        } else {
            return Data()
        }
    }
    
    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy) async throws {
        logger.info("setXattrOf: \(name.string!, privacy: .public)")
        
        if let item = item as? SandboxFSItem {
            item.xattrs[name] = value
        }
    }
    
    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        if let item = item as? SandboxFSItem {
            logger.info("listXattrs: \(item.name.string!, privacy: .public)")
            return Array(item.xattrs.keys)
        } else {
            return []
        }
    }
}


extension SandboxFSVolume: FSVolume.ReadWriteOperations {

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        logger.info("read: \(item)")
        
        var bytesRead = 0
        
        if let item = item as? SandboxFSItem, let data = item.data {
            bytesRead = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                let length = min(buffer.length, data.count)
                _ = buffer.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress, ptr.baseAddress, length)
                }
                return length
            }
        }
        
        return bytesRead
    }
    
    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        logger.info("write: \(item) - \(offset)")
        
        if let item = item as? SandboxFSItem {
            logger.info("- write: \(item.name)")
            item.data = contents
            item.attributes.size = UInt64(contents.count)
            item.attributes.allocSize = UInt64(contents.count)
        }
        
        return contents.count
    }
}

