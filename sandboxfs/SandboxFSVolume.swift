//
//  SandboxFSVolume.swift
//  sandbox
//
//  Created by Sahin Yort on 2025-04-16.
//

import Foundation
import FSKit
import os

final class SandboxFSVolume: FSVolume {
    private let resource: FSResource
    
     let logger = Logger(subsystem: "SandboxFS", category: "Volume")
    
     let root: SandboxFSItem = {
        let item = SandboxFSItem(name: FSFileName(string: "/"))
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
    let version: SandboxFSItem = {
        let item = SandboxFSItem(name: FSFileName(string: "sandbox_fs_version"))
        item.attributes.type = FSItem.ItemType.file
        item.data = "caferin amk".data(using: .utf8)
        item.attributes.size = 6
        item.attributes.allocSize = 6
        item.attributes.mode = UInt32(S_IFREG | 0b111_000_000)
        return item
    }()
    
    init(resource: FSResource) {
        self.resource = resource
        super.init(
            volumeID: FSVolume.Identifier(uuid: Constants.volumeIdentifier),
            volumeName: FSFileName(string: "sandbox")
        )
        
        logger.log("item id is \(self.version.id)")
        self.root.addItem(self.version)
        
        let tmp = SandboxFSItem(name: FSFileName(string: "tmp"))
        tmp.attributes.mode = UInt32(S_IFLNK | 0b111_000_000)
        tmp.attributes.type = .symlink
        tmp.attributes.size = 0
        tmp.attributes.allocSize = 0
        tmp.attributes.flags = 0
        tmp.linkname = FSFileName.init(string: "/private/tmp/tmp")
        tmp.attributes.size = UInt64(tmp.linkname!.data.count)
  
        logger.log("tmp id is \(tmp)")
        self.root.addItem(tmp)
    }
}


extension SandboxFSVolume: FSVolume.PathConfOperations {
    var maximumNameLength: Int {
        return -1
    }
    
    var restrictsOwnershipChanges: Bool {
        return true
    }
    
    var truncatesLongNames: Bool {
        return false
    }
    
    var maximumLinkCount: Int {
        return -1
    }
    
    var maximumXattrSize: Int {
        return Int.max
    }
    
    var maximumFileSize: UInt64 {
        return UInt64.max
    }
    
}

