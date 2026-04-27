#if canImport(FSKit)
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
    var cachedMTime: Date = Date()

    init(kind: FSNodeKind) {
        self.kind = kind
        self.identifier = FSItem.Identifier(rawValue: UInt64(JiraFSItem.stableID(for: kind)))!
        super.init()
    }

    /// Stable, deterministic identifier derived from the kind. Reservation:
    /// `FSItem.Identifier.rootDirectory` (== 2) is reserved for the root.
    static func stableID(for kind: FSNodeKind) -> UInt64 {
        switch kind {
        case .root: return 2 // FSItem.Identifier.rootDirectory.rawValue
        default:
            var hasher = Hasher()
            hasher.combine(String(describing: kind))
            let raw = UInt64(bitPattern: Int64(hasher.finalize()))
            // Avoid collision with reserved identifiers (0 invalid, 1 parent-of-root, 2 root)
            return max(raw, 16)
        }
    }
}
#endif
