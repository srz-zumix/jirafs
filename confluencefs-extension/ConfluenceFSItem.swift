import CryptoKit
import Foundation
import FSKit
import os
import AtlassianCore
import ConfluenceAPI
import ConfluenceFSCore

/// `FSItem` subclass representing a single node in the Confluence-backed volume.
///
/// Most node payloads are loaded lazily on `open` and cached in `cachedData`.
@available(macOS 15.4, *)
final class ConfluenceFSItem: FSItem, @unchecked Sendable {
    let kind: ConfluenceNodeKind
    let identifier: FSItem.Identifier

    // `cachedData`/`cachedSize` are mutated from multiple concurrent FSKit
    // operation tasks: `openItem`, `read`, and `closeItem` each run as an
    // independent `makeTask` closure (or are invoked directly off the FSKit
    // thread), so unsynchronized access is a genuine data race. `Data?` is
    // backed by a reference-counted storage object, so concurrent mutation
    // corrupts ARC. An unfair lock serializes the backing storage; the computed
    // properties keep the same `node.cachedData` / `node.cachedSize` API the
    // call sites already use, and `setPayload` updates the pair atomically.
    private let payloadLock = OSAllocatedUnfairLock()
    private var _cachedData: Data?
    private var _cachedSize: UInt64 = 0

    var cachedData: Data? {
        get { payloadLock.withLock { _cachedData } }
        set { payloadLock.withLock { _cachedData = newValue } }
    }
    var cachedSize: UInt64 {
        get { payloadLock.withLock { _cachedSize } }
        set { payloadLock.withLock { _cachedSize = newValue } }
    }

    /// Replaces the cached payload bytes and size together under a single lock so
    /// a writer never leaves a half-updated pair. The `cachedData` and
    /// `cachedSize` getters lock independently, so reading both is not an atomic
    /// snapshot; this is harmless because the read path slices by
    /// `cachedData.count` and never pairs it with `cachedSize`.
    func setPayload(_ data: Data?, size: UInt64) {
        payloadLock.withLock {
            _cachedData = data
            _cachedSize = size
        }
    }
    // Mutable from both FSKit operation tasks and payload-load callbacks, so the
    // timestamps share `payloadLock` to keep access race-free under Swift 6
    // strict concurrency. Each getter/setter takes the lock independently; mtime
    // and birth time are never required to be a consistent pair.
    private var _cachedMTime: Date = Date()
    private var _cachedBirthTime: Date = Date()
    var cachedMTime: Date {
        get { payloadLock.withLock { _cachedMTime } }
        set { payloadLock.withLock { _cachedMTime = newValue } }
    }
    var cachedBirthTime: Date {
        get { payloadLock.withLock { _cachedBirthTime } }
        set { payloadLock.withLock { _cachedBirthTime = newValue } }
    }

    init(kind: ConfluenceNodeKind) {
        self.kind = kind
        self.identifier = FSItem.Identifier(rawValue: ConfluenceFSItem.stableID(for: kind))!
        super.init()
    }

    /// Creates an item whose `fileID` also depends on its directory-entry
    /// display name. Used for page directories/HTML siblings so that **renaming**
    /// a page (title changes, `pageId` stays the same) produces a *new* fileID.
    /// Finder caches a directory entry's name keyed by its fileID and will not
    /// refresh a renamed entry whose fileID is unchanged; changing the fileID
    /// makes Finder treat the rename as a remove + add and redraw the new name.
    ///
    /// `salt` adds a further fileID input that is independent of the name — used
    /// for the page version on `{Title}.html`, so that **editing** a page (body
    /// changes, name stays the same) also yields a new fileID. Finder caches a
    /// rendered HTML preview keyed by fileID; without a fileID change it keeps
    /// showing the stale rendered preview even though mtime/size changed.
    init(kind: ConfluenceNodeKind, displayName: String?, salt: String? = nil) {
        self.kind = kind
        self.identifier = FSItem.Identifier(rawValue: ConfluenceFSItem.stableID(for: kind, displayName: displayName, salt: salt))!
        super.init()
    }

    /// Stable, deterministic identifier derived from the kind.
    /// Reserved identifiers: 0 = invalid, 2 = root (FSItem.Identifier.rootDirectory).
    ///
    /// `displayName` and `salt` only affect `pageDir`/`pageHtml`; all other kinds
    /// ignore them so their IDs stay purely structural. Passing `nil` reproduces
    /// the legacy name-independent ID (used where the name is not known).
    static func stableID(for kind: ConfluenceNodeKind, displayName: String? = nil, salt: String? = nil) -> UInt64 {
        if case .root = kind { return 2 }
        let canonical = canonicalString(for: kind, displayName: displayName, salt: salt)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let raw = digest.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
        }
        return raw < 16 ? raw &+ 16 : raw
    }

    private static func canonicalString(for kind: ConfluenceNodeKind, displayName: String? = nil, salt: String? = nil) -> String {
        switch kind {
        case .root:                                   return "root"
        case .agentsGuide:                            return "agentsGuide"
        case .spaceAgentsGuide(let key):              return "spaceAgentsGuide:\(key)"
        case .pagesAgentsGuide(let key):              return "pagesAgentsGuide:\(key)"
        case .metadataNeverIndex:                     return "metadataNeverIndex"
        case .configDir:                              return "configDir"
        case .configFile:                             return "configFile"
        case .spacesDir:                              return "spacesDir"
        case .space(let key):                         return "space:\(key)"
        case .spaceMeta(let key):                     return "spaceMeta:\(key)"
        case .pagesDir(let space):                    return "pagesDir:\(space)"
        // Include the display name so a title change (= rename) yields a new
        // fileID, and `salt` (the page version) so an edit does too; see
        // init(kind:displayName:salt:) for why this matters to Finder. When both
        // are nil the name/salt components are omitted entirely so the result is
        // byte-identical to the legacy structural ID (honouring the documented
        // "passing nil reproduces the legacy name-independent ID" contract).
        case .pageDir(let space, let id):
            let base = "pageDir:\(space):\(id)"
            return (displayName == nil && salt == nil) ? base : "\(base):\(displayName ?? ""):\(salt ?? "")"
        case .pageHtml(let space, let id):
            let base = "pageHtml:\(space):\(id)"
            return (displayName == nil && salt == nil) ? base : "\(base):\(displayName ?? ""):\(salt ?? "")"
        case .pageBody(let space, let id):            return "pageBody:\(space):\(id)"
        case .pageMeta(let space, let id):            return "pageMeta:\(space):\(id)"
        case .labels(let space, let id):              return "labels:\(space):\(id)"
        case .commentsDir(let space, let id):         return "commentsDir:\(space):\(id)"
        case .comment(let space, let id, let index):  return "comment:\(space):\(id):\(index)"
        case .attachmentsDir(let space, let id):      return "attachmentsDir:\(space):\(id)"
        case .attachment(let space, let id, let att): return "attachment:\(space):\(id):\(att)"
        case .archivedRootPagesDir(let space):        return "archivedRootPagesDir:\(space)"
        case .archivedChildPagesDir(let space, let id): return "archivedChildPagesDir:\(space):\(id)"
        // Include the display name so a folder rename (title changes, folderId stays the same)
        // yields a new fileID, matching the behaviour of pageDir/pageHtml above.
        case .folderDir(let space, let id):
            let base = "folderDir:\(space):\(id)"
            return displayName == nil ? base : "\(base):\(displayName!)"
        }
    }
}
