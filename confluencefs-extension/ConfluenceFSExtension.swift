import Foundation
import FSKit

/// Entry point for the FSKit unary file system extension.
@available(macOS 15.4, *)
@main
struct ConfluenceFSExtension: UnaryFileSystemExtension {
    let fileSystem = ConfluenceFileSystem()
}
