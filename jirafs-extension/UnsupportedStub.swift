#if !canImport(FSKit)
import Foundation

/// Fallback executable entry point used when building against an SDK that
/// does not yet ship FSKit (Xcode < 16.4). The extension cannot function in
/// this configuration; this stub exists only so the target links.
@main
struct UnsupportedJiraFSExtension {
    static func main() {
        FileHandle.standardError.write(Data("jirafs-extension requires macOS 15.4 SDK / Xcode 16.4+\n".utf8))
        exit(1)
    }
}
#endif
