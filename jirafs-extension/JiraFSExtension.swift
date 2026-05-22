import Foundation
import FSKit

/// Entry point for the FSKit unary file system extension.
@available(macOS 15.4, *)
@main
struct JiraFSExtension: UnaryFileSystemExtension {
    // Must be a stored property so FSKit always gets the same instance.
    let fileSystem = JiraFileSystem()
}
