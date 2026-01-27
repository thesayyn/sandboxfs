
//
//  SandboxFSItem.swift
//  oyoy
//
//  Created by Sahin Yort on 2025-04-16.
//




import Foundation
import FSKit

final class SandboxFSItem: FSItem {
    
    private static var id: UInt64 = FSItem.Identifier.rootDirectory.rawValue + 1
    static func getNextID() -> UInt64 {
        let current = id
        id += 1
        return current
    }
    
    let name: FSFileName
    let id = SandboxFSItem.getNextID()
    
    var attributes = FSItem.Attributes()
    var xattrs: [FSFileName: Data] = [:]
    var data: Data?
    
    var linkname: FSFileName?
    
    private(set) var children: [String: SandboxFSItem] = [:]
    
    init(name: FSFileName) {
        self.name = name
        attributes.fileID = FSItem.Identifier(rawValue: id) ?? .invalid
        attributes.size = 0
        attributes.allocSize = 0
        attributes.flags = 0
        
        var timespec = timespec()
        timespec_get(&timespec, TIME_UTC)
        
        attributes.addedTime = timespec
        attributes.birthTime = timespec
        attributes.changeTime = timespec
        attributes.modifyTime = timespec
    }
    
    func addItem(_ item: SandboxFSItem) {
        item.attributes.parentID = self.attributes.fileID
        children[item.name.string!] = item
    }
    
    func removeItem(_ item: SandboxFSItem) {
        children[item.name.string!] = nil
    }
}
