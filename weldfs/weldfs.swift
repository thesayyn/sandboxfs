import ExtensionFoundation
import Foundation
import FSKit

enum Constants {
    static let containerIdentifier: UUID = UUID(uuidString: "4912d97f-937f-499e-8270-3abf7b69bc49")!
    static let volumeIdentifier: UUID = UUID(uuidString: "a537e475-d305-48b5-bdab-d7cf1f21692a")!
}

@main
struct weldfs: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        weldfsFileSystem()
    }
}
