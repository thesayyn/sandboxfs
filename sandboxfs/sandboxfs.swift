//
//  sandboxfs.swift
//  sandboxfs
//
//  Created by Sahin Yort on 2025-04-16.
//

import Foundation
import FSKit

@main
struct sandboxfs : UnaryFileSystemExtension {
    var fileSystem : FSUnaryFileSystem & FSUnaryFileSystemOperations {
        SandboxFileSystem()
    }
}
