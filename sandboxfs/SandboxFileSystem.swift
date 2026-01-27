//
//  sandboxFileSystem.swift
//  sandbox
//
//  Created by Sahin Yort on 2025-04-16.
//

import Foundation
import FSKit

@objc
class SandboxFileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
    private let logger = Logger(subsystem: "SandboxFS", category: "FS")
    
    
    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        logger.debug("unloadResource: \(resource, privacy: .public)")
        reply(nil)
    }
    
    
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        logger.debug("probeResource: \(resource, privacy: .public)")
        replyHandler(
            FSProbeResult.usable(
                name: "sandbox",
                containerID: FSContainerIdentifier(uuid: Constants.containerIdentifier)
            ), nil
        )
    }
    
    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        containerStatus = .ready
       logger.debug("loadResource: \(resource, privacy: .public)")
       replyHandler(
           SandboxFSVolume(resource: resource),
           nil
       )
    }

}
