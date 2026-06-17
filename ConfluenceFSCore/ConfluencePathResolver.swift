import Foundation

/// Identifies what Confluence resource a filesystem path maps to.
///
/// Pages are addressed by their stable `pageId`; the volume maps a sanitized
/// page **title** in a path to its `pageId` via `PageDataSource`. Child pages
/// nest inside their parent's directory, so `pageDir`/`pageHtml` can appear
/// either directly under `pagesDir` (root pages) or under another `pageDir`
/// (child pages).
public enum ConfluenceNodeKind: Hashable, Sendable {
    case root
    case agentsGuide                              // /AGENTS.md
    case metadataNeverIndex                       // /.metadata_never_index
    case configDir                                // /.confluencefs
    case configFile                               // /.confluencefs/config.json
    case spacesDir                                // /spaces
    case space(key: String)                       // /spaces/{KEY}
    case spaceMeta(key: String)                   // /spaces/{KEY}/.space.json
    case pagesDir(spaceKey: String)               // /spaces/{KEY}/pages
    case pageDir(spaceKey: String, pageId: String)   // .../{Title}/
    case pageHtml(spaceKey: String, pageId: String)  // .../{Title}.html (htmlView only)
    case pageBody(spaceKey: String, pageId: String)  // .../{Title}/page.md
    case pageMeta(spaceKey: String, pageId: String)  // .../{Title}/.metadata.json
    case labels(spaceKey: String, pageId: String)    // .../{Title}/.labels.txt
    case commentsDir(spaceKey: String, pageId: String)
    case comment(spaceKey: String, pageId: String, index: Int) // 1-based, stable
    case attachmentsDir(spaceKey: String, pageId: String)
    case attachment(spaceKey: String, pageId: String, attachmentId: String)
    /// `.archived/` directory under `pagesDir` — lists archived root pages.
    case archivedRootPagesDir(spaceKey: String)
    /// `.archived/` directory under a `pageDir` — lists archived child pages.
    case archivedChildPagesDir(spaceKey: String, pageId: String)

    public var isDirectory: Bool {
        switch self {
        case .root, .configDir, .spacesDir, .space, .pagesDir, .pageDir,
             .commentsDir, .attachmentsDir,
             .archivedRootPagesDir, .archivedChildPagesDir:
            return true
        default:
            return false
        }
    }
}

extension ConfluenceNodeKind: CustomStringConvertible {
    /// Human-readable description used by logging and `String(describing:)`.
    /// A custom implementation avoids Mirror-based reflection, which can overflow
    /// the stack when many async continuations are stacked on the cooperative thread.
    public var description: String {
        switch self {
        case .root:                                   return "root"
        case .agentsGuide:                            return "agentsGuide"
        case .metadataNeverIndex:                     return "metadataNeverIndex"
        case .configDir:                              return "configDir"
        case .configFile:                             return "configFile"
        case .spacesDir:                              return "spacesDir"
        case .space(let key):                         return "space(\(key))"
        case .spaceMeta(let key):                     return "spaceMeta(\(key))"
        case .pagesDir(let spaceKey):                 return "pagesDir(\(spaceKey))"
        case .pageDir(let spaceKey, let pageId):      return "pageDir(\(spaceKey),\(pageId))"
        case .pageHtml(let spaceKey, let pageId):     return "pageHtml(\(spaceKey),\(pageId))"
        case .pageBody(let spaceKey, let pageId):     return "pageBody(\(spaceKey),\(pageId))"
        case .pageMeta(let spaceKey, let pageId):     return "pageMeta(\(spaceKey),\(pageId))"
        case .labels(let spaceKey, let pageId):       return "labels(\(spaceKey),\(pageId))"
        case .commentsDir(let spaceKey, let pageId):  return "commentsDir(\(spaceKey),\(pageId))"
        case .comment(let spaceKey, let pageId, let index):
            return "comment(\(spaceKey),\(pageId),\(index))"
        case .attachmentsDir(let spaceKey, let pageId):
            return "attachmentsDir(\(spaceKey),\(pageId))"
        case .attachment(let spaceKey, let pageId, let attachmentId):
            return "attachment(\(spaceKey),\(pageId),\(attachmentId))"
        case .archivedRootPagesDir(let spaceKey):     return "archivedRootPagesDir(\(spaceKey))"
        case .archivedChildPagesDir(let spaceKey, let pageId):
            return "archivedChildPagesDir(\(spaceKey),\(pageId))"
        }
    }
}

/// Validates and converts between filesystem paths and `ConfluenceNodeKind`s.
public enum ConfluencePathResolver {
    /// Static files exposed inside a page directory (`{Title}/`).
    public enum PageFile: String, CaseIterable, Sendable {
        case body = "page.md"
        case metadata = ".metadata.json"
        case labels = ".labels.txt"
    }

    /// Static children of a page directory (the dynamic child pages are resolved
    /// separately by the volume via `PageDataSource`).
    public static func pageDirStaticChildren(spaceKey: String, pageId: String)
        -> [(name: String, kind: ConfluenceNodeKind)]
    {
        [
            (PageFile.body.rawValue, .pageBody(spaceKey: spaceKey, pageId: pageId)),
            (PageFile.metadata.rawValue, .pageMeta(spaceKey: spaceKey, pageId: pageId)),
            (PageFile.labels.rawValue, .labels(spaceKey: spaceKey, pageId: pageId)),
            (".comments", .commentsDir(spaceKey: spaceKey, pageId: pageId)),
            (".attachments", .attachmentsDir(spaceKey: spaceKey, pageId: pageId)),
        ]
    }

    /// Returns the **static** children of a node (those resolvable without a
    /// network call). Dynamic children — space keys under `spacesDir`, root
    /// pages under `pagesDir`, child pages under a `pageDir`, comments and
    /// attachments — are supplied by the caller.
    public static func childKinds(of parent: ConfluenceNodeKind, spaceKeys: [String] = [])
        -> [(name: String, kind: ConfluenceNodeKind)]
    {
        switch parent {
        case .root:
            return [
                ("spaces", .spacesDir),
                ("AGENTS.md", .agentsGuide),
                (".confluencefs", .configDir),
                (".metadata_never_index", .metadataNeverIndex),
            ]
        case .configDir:
            return [("config.json", .configFile)]
        case .spacesDir:
            return spaceKeys.map { ($0, ConfluenceNodeKind.space(key: $0)) }
        case .space(let key):
            return [
                (".space.json", .spaceMeta(key: key)),
                ("pages", .pagesDir(spaceKey: key)),
            ]
        case .pageDir(let spaceKey, let pageId):
            return pageDirStaticChildren(spaceKey: spaceKey, pageId: pageId)
        default:
            return []
        }
    }

    /// Resolves a child name against a parent kind for static children only.
    /// Returns nil if the name maps to a dynamic resource (page title, comment,
    /// attachment) that the caller must resolve via `PageDataSource`.
    public static func staticChild(name: String, of parent: ConfluenceNodeKind, spaceKeys: [String] = [])
        -> ConfluenceNodeKind?
    {
        for (n, k) in childKinds(of: parent, spaceKeys: spaceKeys) where n == name {
            return k
        }
        return nil
    }
}
