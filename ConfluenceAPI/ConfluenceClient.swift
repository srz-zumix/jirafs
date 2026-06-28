import Foundation
import AtlassianCore

/// Confluence edition. Cloud uses REST API v2 (`/wiki/api/v2/`) with cursor
/// pagination; Data Center / Server uses REST API v1 (`/rest/api/`) with
/// start/limit pagination.
public enum ConfluenceEdition: String, Codable, Sendable {
    case cloud
    case dataCenter

    /// `true` when the instance speaks the Cloud v2 REST dialect.
    public var isCloud: Bool { self == .cloud }
}

/// The body representation requested when fetching a page.
public enum ConfluenceBodyFormat: String, Codable, Sendable {
    /// Confluence storage format (XHTML). Available on both Cloud and DC.
    case storage
    /// Atlassian Document Format (JSON). Cloud only.
    case atlasDocFormat = "atlas_doc_format"
    /// Server-rendered HTML view. Dynamic macros (e.g. Table of Contents) are
    /// evaluated server-side. Available on both Cloud (`body-format=view`) and
    /// DC (`expand=body.view`).
    case view
}

/// Configuration for a single Confluence instance.
public struct ConfluenceInstanceConfig: Sendable, Equatable {
    public let name: String
    public let baseURL: URL
    public let edition: ConfluenceEdition

    public init(name: String, baseURL: URL, edition: ConfluenceEdition) {
        self.name = name
        self.baseURL = baseURL
        self.edition = edition
    }
}

/// A page of results plus an opaque cursor for fetching the next page.
public struct ConfluencePageList<Element: Sendable>: Sendable {
    public let items: [Element]
    /// Opaque pagination cursor. `nil` means there are no further pages.
    public let nextCursor: String?

    public init(items: [Element], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Common Confluence REST client interface used by the FSKit volume.
public protocol ConfluenceClient: Sendable {
    var config: ConfluenceInstanceConfig { get }

    /// Lists spaces, one page at a time. Pass the previous result's
    /// `nextCursor` to continue; `nil` starts at the beginning.
    func listSpaces(cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceSpace>

    /// Lists the **root** (top-level) pages of a space. The whole space is
    /// passed because Cloud keys pages by `space.id` while Data Center keys
    /// them by `space.key`. Only pages with status `current` are returned.
    func listRootPages(space: ConfluenceSpace, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluencePage>

    /// Lists archived root pages of a space (`status=archived`).
    func listArchivedRootPages(space: ConfluenceSpace, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluencePage>

    /// Lists the direct child pages of a page (status `current` only).
    func listChildPages(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluencePage>

    /// Lists archived direct child pages of a page.
    func listArchivedChildPages(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluencePage>

    /// Fetches a single page including its body in the requested format.
    func getPage(id: String, bodyFormat: ConfluenceBodyFormat) async throws -> ConfluencePage

    func listComments(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceComment>
    func listAttachments(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceAttachment>
    func listLabels(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceLabel>

    /// Downloads an attachment body, optionally a bounded byte window via an HTTP
    /// `Range` request. The returned ``RangedDownload`` reports whether the server
    /// honored the range (`206`) or returned the whole body (`200`).
    func downloadAttachment(_ attachment: ConfluenceAttachment, range: Range<Int>?) async throws -> RangedDownload

    /// Probes the total byte size of an attachment without downloading its body,
    /// for attachments whose listing metadata omits `fileSize` (unknown size).
    /// Issues an HTTP `HEAD` and reads `Content-Length`. Returns `nil` when the
    /// server does not report a determinable size. A `HEAD` is used (rather than
    /// a ranged `GET`) so a server that ignores `Range` cannot be coerced into
    /// streaming the whole file into memory while probing.
    func attachmentSize(_ attachment: ConfluenceAttachment) async throws -> Int?

    /// Lists the direct children (pages, sub-folders, etc.) of a **page** via
    /// `GET /wiki/api/v2/pages/{id}/direct-children` (Cloud only; DC always returns empty).
    /// The result is a mixed list tagged by `contentType`; callers filter as needed.
    func listPageDirectChildren(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceFolderChild>

    /// Lists the direct children (pages and sub-folders) of a **folder** via
    /// `GET /wiki/api/v2/folders/{id}/direct-children` (Cloud only; DC always returns empty).
    func listFolderChildren(folderId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceFolderChild>

    /// Returns the IDs of **root** pages (depth=root) of a space that have any
    /// user/group restriction (read or update). Cloud uses v1 Space content API
    /// scoped to `depth=root`; Data Center always returns an empty set because
    /// restriction data is embedded inline via `expand` in the list response.
    /// - Parameters:
    ///   - spaceKey: The space key (e.g. "DOC").
    ///   - status: `"current"` or `"archived"`.
    ///   - limiter: Wraps each page request so 429 / server-error retries and
    ///     backoff are applied per page during pagination.
    func restrictedRootPageIDs(spaceKey: String, status: String, limiter: RateLimiter) async throws -> Set<String>

    /// Returns the IDs of **direct child pages** of `pageId` that have any
    /// user/group restriction. Same Cloud/DC split as `restrictedRootPageIDs`.
    /// - Parameters:
    ///   - pageId: The parent page ID.
    ///   - status: `"current"` or `"archived"`.
    ///   - limiter: Wraps each page request so 429 / server-error retries and
    ///     backoff are applied per page during pagination.
    func restrictedChildPageIDs(pageId: String, status: String, limiter: RateLimiter) async throws -> Set<String>
}
