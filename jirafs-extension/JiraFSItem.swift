import CryptoKit
import Foundation
import FSKit
import JiraAPI
import JiraFSCore

/// `FSItem` subclass representing a single node in the JIRA-backed volume.
///
/// Most node payloads are loaded lazily on `open` and cached in `cachedData`.
@available(macOS 15.4, *)
final class JiraFSItem: FSItem, @unchecked Sendable {
    let kind: FSNodeKind
    let identifier: FSItem.Identifier
    var cachedData: Data?
    var cachedSize: UInt64 = 0
    // Mutable from both FSKit operation tasks and the IssueDataSource change-notification
    // callback. `nonisolated(unsafe)` opts out of Swift 6 isolation checks; Date is a
    // simple struct (Double-backed) whose assignment is effectively atomic on 64-bit
    // platforms, so a torn read/write is not possible.
    nonisolated(unsafe) var cachedMTime: Date = Date()

    init(kind: FSNodeKind) {
        self.kind = kind
        self.identifier = FSItem.Identifier(rawValue: UInt64(JiraFSItem.stableID(for: kind)))!
        super.init()
    }

    /// Stable, deterministic identifier derived from the kind.
    /// Uses the first 8 bytes of SHA-256(canonical-string) so the value is
    /// identical across processes and reboots. Reserved identifiers:
    ///   0 = invalid, 1 = parent-of-root, 2 = root (FSItem.Identifier.rootDirectory)
    static func stableID(for kind: FSNodeKind) -> UInt64 {
        switch kind {
        case .root: return 2 // FSItem.Identifier.rootDirectory.rawValue
        default:
            // Build a canonical string that uniquely identifies each node kind.
            let canonical: String
            switch kind {
            case .root:                             canonical = "root"
            case .agentsGuide:                      canonical = "agentsGuide"
            case .issuesAgentsGuide(let project):   canonical = "issuesAgentsGuide:\(project)"
            case .projectsDir:                      canonical = "projectsDir"
            case .configFile:                       canonical = "configFile"
            case .configDir:                        canonical = "configDir"
            case .metadataNeverIndex:               canonical = "metadataNeverIndex"
            case .project(let key):                 canonical = "project:\(key)"
            case .projectMeta(let key):             canonical = "projectMeta:\(key)"
            case .issuesDir(let proj):              canonical = "issuesDir:\(proj)"
            case .issue(let key):                   canonical = "issue:\(key)"
            case .summary(let key):                 canonical = "summary:\(key)"
            case .description(let key):             canonical = "description:\(key)"
            case .metadata(let key):                canonical = "metadata:\(key)"
            case .commentsDir(let key):             canonical = "commentsDir:\(key)"
            case .comment(let key, let index):      canonical = "comment:\(key):\(index)"
            case .attachmentsDir(let key):          canonical = "attachmentsDir:\(key)"
            case .attachment(let key, let attId):   canonical = "attachment:\(key):\(attId)"
            case .issueHtml(let key):               canonical = "issueHtml:\(key)"
            }
            let digest = SHA256.hash(data: Data(canonical.utf8))
            // Take the first 8 bytes (little-endian) for a UInt64.
            let raw = digest.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            }
            // Reserve 0-15 for special identifiers; shift up if necessary.
            return raw < 16 ? raw &+ 16 : raw
        }
    }
}
