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
