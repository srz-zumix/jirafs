import Foundation
import os
import AtlassianCore
import ConfluenceAPI

/// A directory entry for a page: the sanitized folder stem plus the page.
/// The HTML sibling (when enabled) uses `folderName + ".html"`, so both share
/// the same stem and stay aligned through deduplication.
public struct ConfluencePageEntry: Codable, Sendable, Equatable {
    public let folderName: String
    public let page: ConfluencePage
    public init(folderName: String, page: ConfluencePage) {
        self.folderName = folderName
        self.page = page
    }
}

/// A directory entry for a Confluence folder: the sanitized folder name plus the folder object.
/// Cloud only; always empty on Data Center.
public struct ConfluenceFolderEntry: Codable, Sendable, Equatable {
    public let folderName: String
    public let folder: ConfluenceFolder
    public init(folderName: String, folder: ConfluenceFolder) {
        self.folderName = folderName
        self.folder = folder
    }
}

/// A directory entry for a Confluence whiteboard: the sanitized on-disk
/// directory name plus the whiteboard object. Cloud only; always empty on Data
/// Center. `folderName` matches the naming used by `ConfluencePageEntry` /
/// `ConfluenceFolderEntry` and means "the name of the directory this entry is
/// exposed as", not that the whiteboard is a folder.
public struct ConfluenceWhiteboardEntry: Codable, Sendable, Equatable {
    public let folderName: String
    public let whiteboard: ConfluenceWhiteboard
    public init(folderName: String, whiteboard: ConfluenceWhiteboard) {
        self.folderName = folderName
        self.whiteboard = whiteboard
    }
}

/// Combined result of a container-children fetch: pages, sub-folders and
/// whiteboards together. Cached as a unit so one network round-trip fills every
/// listing type.
public struct ConfluenceFolderChildrenResult: Codable, Sendable, Equatable {
    public let pages: [ConfluencePageEntry]
    public let folders: [ConfluenceFolderEntry]
    public let whiteboards: [ConfluenceWhiteboardEntry]
    public init(
        pages: [ConfluencePageEntry],
        folders: [ConfluenceFolderEntry],
        whiteboards: [ConfluenceWhiteboardEntry] = []
    ) {
        self.pages = pages
        self.folders = folders
        self.whiteboards = whiteboards
    }

    /// Decodes `whiteboards` leniently so entries written to the disk cache
    /// before whiteboard support existed still decode (as an empty list) instead
    /// of failing and dropping the whole cached listing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = try c.decode([ConfluencePageEntry].self, forKey: .pages)
        folders = try c.decode([ConfluenceFolderEntry].self, forKey: .folders)
        whiteboards = try c.decodeIfPresent([ConfluenceWhiteboardEntry].self, forKey: .whiteboards) ?? []
    }

    public static let empty = ConfluenceFolderChildrenResult(pages: [], folders: [], whiteboards: [])
}

/// Container children of a page: the folders and whiteboards nested directly
/// under it. Child *pages* are listed separately (via the child-pages endpoint),
/// so they are not part of this result.
public struct ConfluenceContainerEntries: Codable, Sendable, Equatable {
    public let folders: [ConfluenceFolderEntry]
    public let whiteboards: [ConfluenceWhiteboardEntry]
    public init(folders: [ConfluenceFolderEntry], whiteboards: [ConfluenceWhiteboardEntry] = []) {
        self.folders = folders
        self.whiteboards = whiteboards
    }

    /// Lenient decoding for cache entries written before whiteboard support.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decode([ConfluenceFolderEntry].self, forKey: .folders)
        whiteboards = try c.decodeIfPresent([ConfluenceWhiteboardEntry].self, forKey: .whiteboards) ?? []
    }

    public static let empty = ConfluenceContainerEntries(folders: [], whiteboards: [])
}

/// High-level, cache-aware read-only data source backing the Confluence volume.
///
/// Mirrors `IssueDataSource`: fresh cache → return; stale cache → return and
/// refresh in the background; cold → synchronous fetch. Page bodies are always
/// requested in `storage` format (supported by both Cloud and DC).
public actor PageDataSource {
    public let client: any ConfluenceClient
    public let cache: CacheManager
    public let ttl: ConfluenceConfiguration.CacheTTLConfig
    public let limit: Int
    /// Space-key allowlist. `nil` = all spaces; non-empty = only listed keys.
    public let allowedSpaceKeys: [String]?
    /// When `true`, archived pages are included in page listings.
    public let includeArchived: Bool
    /// When `false` (default), pages with any user/group restriction (read or update)
    /// are excluded from listings. Set to `true` to show restricted pages.
    public let includeRestricted: Bool
    /// When `true`, page bodies are fetched in the server-rendered `view`
    /// representation so dynamic macros (e.g. Table of Contents) arrive already
    /// expanded. Defaults to `true` (raw storage format when disabled).
    public let renderMacros: Bool
    /// Rovo MCP source for whiteboard canvases. `nil` (default) disables the
    /// feature and hides `whiteboard.md` / `whiteboard.json` / `whiteboard.svg`.
    public let rovoWhiteboards: RovoWhiteboardSource?
    private let limiter: RateLimiter
    private let logger = AtlassianLog.logger("confluence-datasource")

    private var refreshing: Set<String> = []
    /// In-flight background refresh tasks, keyed by refresh key. Tracked so they
    /// can be cancelled on unmount; an untracked `Task` would otherwise keep
    /// issuing network requests (and retaining this actor, its HTTP client, and
    /// the cache) after the volume is torn down.
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    /// Single-flight guard for Cloud restricted-page-ID fetches. Prevents N
    /// concurrent tasks from each initiating the same directory-scoped
    /// restricted-ID fetch (root pages of a space, or one parent's children)
    /// when the background pre-caching fills child-page entries in parallel.
    private var pendingRestrictedIDsFetch: [String: Task<Set<String>, Error>] = [:]
    /// Single-flight guard for Rovo MCP whiteboard-canvas fetches, keyed by
    /// whiteboard ID. `whiteboard.md`, `.json` and `.svg` all resolve to the same
    /// canvas, so concurrent opens would otherwise each miss the cache and issue
    /// a separate (rate-limited, credit-billed) MCP call.
    private var pendingWhiteboardContentFetch: [String: Task<String, Error>] = [:]

    /// Shared attachment byte cache: serves bounded windows of attachment bodies
    /// (streaming large files via HTTP `Range`, caching small bodies in memory).
    /// If the server ignores `Range` and returns a `200` full body, the body is
    /// cached only when it fits under `maxInlineAttachmentBytes`. Cleared on
    /// `synchronize()` and unmount.
    private let attachmentBytes: AttachmentByteCache

    /// Default inline-attachment threshold: attachments at or below this size are
    /// downloaded once and cached in memory, then served as in-memory slices
    /// instead of issuing repeated ranged requests. **16 MiB.**
    public static let defaultMaxInlineAttachmentBytes = 16 * 1024 * 1024

    /// Attachments at or below this size are cached whole in memory and served as
    /// in-memory slices. Forwarded to the shared ``AttachmentByteCache``.
    public let maxInlineAttachmentBytes: Int

    /// Directory node kinds whose page listing has been enumerated at least once
    /// (i.e. directories the user has actually browsed). The periodic poll only
    /// refreshes these, so spaces/pages that were never opened don't generate
    /// API traffic. Only page-listing directory kinds are inserted
    /// (`pagesDir` / `pageDir` / `archivedRootPagesDir` / `archivedChildPagesDir`).
    ///
    /// Capped at `maxBrowsedListings` to prevent spawning an unbounded number of
    /// Tasks in `refreshBrowsedListings()`. Each entry becomes one Task whose
    /// continuation sits on the cooperative-thread stack; a very large set
    /// (thousands of entries) exhausts the stack and causes a SIGBUS crash.
    private var browsedListings: Set<ConfluenceNodeKind> = []
    private static let maxBrowsedListings = 500

    /// Reference-type wrapper for the listing-refreshed handler closure.
    ///
    /// The handler is read out of its lock (`refreshedHandler.withLock { $0 }`)
    /// after *every* background refresh. Reading a bare closure value back through
    /// `OSAllocatedUnfairLock`'s generic `withLock` re-abstracts it and writes the
    /// deeper-abstracted form back into the stored slot, so each read adds one
    /// reabstraction-thunk layer to the stored closure. After a couple of thousand
    /// refreshes the stored closure is thousands of thunks deep, and the next
    /// invocation (whose body logs via `os_log`) unwinds through all of them and
    /// overflows the thread's small stack → `SIGBUS`. Boxing the closure in a
    /// class makes the stored value a plain reference: reads return the box
    /// pointer unchanged, so no thunk layers ever accumulate.
    private final class ListingRefreshedHandlerBox: Sendable {
        let fire: @Sendable (ConfluenceNodeKind) -> Void
        init(_ fire: @escaping @Sendable (ConfluenceNodeKind) -> Void) { self.fire = fire }
    }

    /// Called on the actor's executor after every successful background refresh
    /// of a page-listing directory. The parameter is the directory node kind.
    /// `ConfluenceVolume` uses this to bump the directory's `cachedMTime` so
    /// Finder's kqueue watcher fires and the listing auto-refreshes.
    ///
    /// Stored behind a lock (rather than as actor-isolated state) so the volume
    /// can install it *synchronously* at construction time — before FSKit can
    /// issue the first `enumerateDirectory`/`lookupItem`. Otherwise an early
    /// background refresh could complete before an async setter ran, refreshing
    /// the cache without bumping the directory mtime, and Finder would keep
    /// serving a stale listing. Boxed in a class (see `ListingRefreshedHandlerBox`)
    /// so repeated reads don't accumulate reabstraction thunks.
    private let refreshedHandler = OSAllocatedUnfairLock<ListingRefreshedHandlerBox?>(initialState: nil)

    /// Serial GCD queue used to fire `refreshedHandler` off the Swift cooperative
    /// thread pool. The handler body logs via `os_log` (which needs substantial
    /// stack); running it on a dedicated full-size thread stack — and serializing
    /// invocations when a burst of refresh tasks complete at once — keeps that
    /// logging off the small cooperative-thread stacks.
    private let refreshNotifyQueue = DispatchQueue(label: "com.zumix.jirafs.confluence.listing-refresh-notify")

    /// Installs the handler invoked after every successful background refresh of a
    /// page-listing directory. `nonisolated` + synchronous so it can run during
    /// volume construction, guaranteeing the handler is in place before any
    /// refresh can fire (see `refreshedHandler`).
    public nonisolated func setListingRefreshedHandler(_ handler: @escaping @Sendable (ConfluenceNodeKind) -> Void) {
        refreshedHandler.withLock { $0 = ListingRefreshedHandlerBox(handler) }
    }

    /// Records that a page-listing directory has been browsed so the periodic
    /// poll keeps it fresh. Non-page-listing kinds are ignored.
    ///
    /// Once `maxBrowsedListings` is reached, new entries are dropped — older
    /// tracked directories keep their periodic refreshes, and newly-browsed
    /// directories fall back to the normal stale-while-revalidate path instead.
    public func markBrowsed(_ kind: ConfluenceNodeKind) {
        switch kind {
        case .pagesDir, .pageDir, .archivedRootPagesDir, .archivedChildPagesDir,
             .folderDir, .whiteboardDir:
            guard browsedListings.count < PageDataSource.maxBrowsedListings else { return }
            browsedListings.insert(kind)
        default:
            break
        }
    }

    public init(
        client: any ConfluenceClient,
        cache: CacheManager = CacheManager(),
        ttl: ConfluenceConfiguration.CacheTTLConfig = .default,
        limit: Int = 100,
        allowedSpaceKeys: [String]? = nil,
        includeArchived: Bool = false,
        includeRestricted: Bool = false,
        renderMacros: Bool = true,
        rovoWhiteboards: RovoWhiteboardSource? = nil,
        maxInlineAttachmentBytes: Int = PageDataSource.defaultMaxInlineAttachmentBytes,
        limiter: RateLimiter = RateLimiter()
    ) {
        self.client = client
        self.cache = cache
        self.ttl = ttl
        self.limit = limit
        self.includeArchived = includeArchived
        self.includeRestricted = includeRestricted
        self.renderMacros = renderMacros
        self.rovoWhiteboards = rovoWhiteboards
        let normalizedMaxInlineAttachmentBytes = max(0, maxInlineAttachmentBytes)
        self.maxInlineAttachmentBytes = normalizedMaxInlineAttachmentBytes
        self.attachmentBytes = AttachmentByteCache(maxInlineBytes: normalizedMaxInlineAttachmentBytes)
        if let raw = allowedSpaceKeys {
            var seen = Set<String>()
            let normalized = raw
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            self.allowedSpaceKeys = normalized.isEmpty ? nil : normalized
        } else {
            self.allowedSpaceKeys = nil
        }
        self.limiter = limiter
    }

    public func synchronize() async {
        await cache.synchronize()
        await attachmentBytes.clear()
    }

    /// Force a background refresh of every page-listing directory the user has
    /// browsed at least once.
    ///
    /// `ConfluenceVolume` calls this on a timer (interval ≈ `ttl.pages`) so that
    /// pages created in Confluence after the directory was last enumerated
    /// appear without the user having to re-trigger enumeration. Each refresh
    /// fires `onListingRefreshed`, which bumps the directory `cachedMTime` so
    /// Finder's kqueue watcher re-enumerates and surfaces the new entries.
    ///
    /// A `refreshing` guard prevents a poll that overlaps an in-flight refresh
    /// for the same directory from issuing a duplicate fetch.
    ///
    /// - Returns: the number of browsed listings a refresh was scheduled for.
    @discardableResult
    public func refreshBrowsedListings() async -> Int {
        var scheduled = 0
        for kind in browsedListings {
            let refreshKey = "listing-refresh/\(kind)"
            guard !refreshing.contains(refreshKey) else { continue }
            refreshing.insert(refreshKey)
            scheduled += 1
            refreshTasks[refreshKey] = Task {
                defer { self.clearRefreshing(refreshKey) }
                await self.forceRefreshListing(kind)
            }
        }
        return scheduled
    }

    /// Performs a fresh network fetch for one page-listing directory, overwrites
    /// the cache, and fires `onListingRefreshed`. Mirrors JIRA's
    /// `bgRefreshIssueKeys`: it always hits the network (rather than honouring
    /// the SWR short-circuit) so the listing is actually brought up to date.
    private func forceRefreshListing(_ kind: ConfluenceNodeKind) async {
        do {
            switch kind {
            case .pagesDir(let spaceKey):
                guard let space = try await space(key: spaceKey) else { return }
                let entries = try await fetchRootPageEntries(space: space)
                await cache.set("rootpages/\(space.key)/\(pageListVariant)", value: entries, ttl: ttl.pages)
            case .archivedRootPagesDir(let spaceKey):
                guard includeArchived, let space = try await space(key: spaceKey) else { return }
                let entries = try await fetchArchivedRootPageEntries(space: space)
                await cache.set("archivedRootPages/\(space.key)/\(pageListVariant)", value: entries, ttl: ttl.pages)
            case .pageDir(let spaceKey, let pageId):
                let normalized = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
                let entries = try await fetchChildPageEntries(pageId: pageId, normalizedSpace: normalized)
                await cache.set("childpages/\(normalized)/\(pageId)/\(pageListVariant)", value: entries, ttl: ttl.pages)
                // Folder refresh errors are non-fatal — a failure here should not
                // prevent the child-page listing from being committed to the cache.
                if client.config.edition.isCloud {
                    if let containers = try? await fetchPageContainerEntries(pageId: pageId) {
                        await cache.set("pagecontainers/\(normalized)/\(pageId)/\(pageListVariant)", value: containers, ttl: ttl.pages)
                    }
                }
            case .archivedChildPagesDir(let spaceKey, let pageId):
                guard includeArchived else { return }
                let normalized = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
                let entries = try await fetchArchivedChildPageEntries(pageId: pageId, normalizedSpace: normalized)
                await cache.set("archivedChildPages/\(normalized)/\(pageId)/\(pageListVariant)", value: entries, ttl: ttl.pages)
            case .folderDir(let spaceKey, let folderId):
                let normalized = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
                let result = try await fetchFolderChildren(folderId: folderId, normalizedSpace: normalized)
                await cache.set("folderchildren/\(normalized)/\(folderId)/\(pageListVariant)", value: result, ttl: ttl.pages)
            case .whiteboardDir(let spaceKey, let whiteboardId):
                let normalized = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
                let result = try await fetchWhiteboardChildren(whiteboardId: whiteboardId, normalizedSpace: normalized)
                await cache.set("whiteboardchildren/\(normalized)/\(whiteboardId)/\(pageListVariant)", value: result, ttl: ttl.pages)
            default:
                return
            }
            // Fire the listing-refreshed handler off the cooperative thread (see
            // `refreshNotifyQueue`). The handler is boxed (see
            // `ListingRefreshedHandlerBox`) so reading it here never accumulates
            // reabstraction thunks on the stored closure.
            if let box = refreshedHandler.withLock({ $0 }) {
                refreshNotifyQueue.async { box.fire(kind) }
            }
        } catch {
            logger.debug("forceRefreshListing failed kind=\(String(describing: kind), privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Spaces

    public func spaces() async throws -> [ConfluenceSpace] {
        // Cache the full (unfiltered) space list so that changing the allowlist
        // never invalidates the cache — the filter is applied in-memory after
        // reading from cache.
        let all: [ConfluenceSpace] = try await cached("spaces", ttl: ttl.spaces) {
            try await self.fetchAll { cursor in
                try await self.client.listSpaces(cursor: cursor, limit: self.limit)
            }
        }
        guard let allowed = allowedSpaceKeys else {
            return all.sorted { $0.key < $1.key }
        }
        let set = Set(allowed)
        return all
            .filter { set.contains($0.key.uppercased()) }
            .sorted { $0.key < $1.key }
    }

    public func space(key: String) async throws -> ConfluenceSpace? {
        try await spaces().first { $0.key == key }
    }

    // MARK: - Pages

    /// Cache key suffix that varies with settings affecting page-list contents.
    /// Embedding this in the key ensures that changing `includeRestricted` never
    /// serves a cached result that was computed under the opposite setting.
    private var pageListVariant: String { includeRestricted ? "r1" : "r0" }

    /// Sanitized, deduplicated root-page entries for a space, sorted by title.
    public func rootPageEntries(space: ConfluenceSpace) async throws -> [ConfluencePageEntry] {
        try await cached("rootpages/\(space.key)/\(pageListVariant)", ttl: ttl.pages) {
            try await self.fetchRootPageEntries(space: space)
        }
    }

    private func fetchRootPageEntries(space: ConfluenceSpace) async throws -> [ConfluencePageEntry] {
        let pages = try await self.fetchAll { cursor in
            try await self.client.listRootPages(space: space, cursor: cursor, limit: self.limit)
        }
        let filtered = try await self.filterRestricted(
            pages,
            restrictedIDsKey: "restrictedIDs/root/\(space.key)/current"
        ) { try await self.client.restrictedRootPageIDs(spaceKey: space.key, status: "current", limiter: self.limiter) }
        return self.makeEntries(filtered)
    }

    /// Sanitized, deduplicated archived root-page entries. Only fetched when `includeArchived` is true.
    public func archivedRootPageEntries(space: ConfluenceSpace) async throws -> [ConfluencePageEntry] {
        guard includeArchived else { return [] }
        return try await cached("archivedRootPages/\(space.key)/\(pageListVariant)", ttl: ttl.pages) {
            try await self.fetchArchivedRootPageEntries(space: space)
        }
    }

    private func fetchArchivedRootPageEntries(space: ConfluenceSpace) async throws -> [ConfluencePageEntry] {
        let pages = try await self.fetchAll { cursor in
            try await self.client.listArchivedRootPages(space: space, cursor: cursor, limit: self.limit)
        }
        let filtered = try await self.filterRestricted(
            pages,
            restrictedIDsKey: "restrictedIDs/root/\(space.key)/archived"
        ) { try await self.client.restrictedRootPageIDs(spaceKey: space.key, status: "archived", limiter: self.limiter) }
        return self.makeEntries(filtered)
    }

    /// Sanitized, deduplicated child-page entries for a page, sorted by title.
    public func childPageEntries(pageId: String, spaceKey: String) async throws -> [ConfluencePageEntry] {
        let space = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
        return try await cached("childpages/\(space)/\(pageId)/\(pageListVariant)", ttl: ttl.pages) {
            try await self.fetchChildPageEntries(pageId: pageId, normalizedSpace: space)
        }
    }

    private func fetchChildPageEntries(pageId: String, normalizedSpace space: String) async throws -> [ConfluencePageEntry] {
        let pages = try await self.fetchAll { cursor in
            try await self.client.listChildPages(pageId: pageId, cursor: cursor, limit: self.limit)
        }
        let filtered = try await self.filterRestricted(
            pages,
            restrictedIDsKey: "restrictedIDs/children/\(space)/\(pageId)/current"
        ) { try await self.client.restrictedChildPageIDs(pageId: pageId, status: "current", limiter: self.limiter) }
        return self.makeEntries(filtered)
    }

    /// Sanitized, deduplicated archived child-page entries. Only fetched when `includeArchived` is true.
    public func archivedChildPageEntries(pageId: String, spaceKey: String) async throws -> [ConfluencePageEntry] {
        guard includeArchived else { return [] }
        let space = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
        return try await cached("archivedChildPages/\(space)/\(pageId)/\(pageListVariant)", ttl: ttl.pages) {
            try await self.fetchArchivedChildPageEntries(pageId: pageId, normalizedSpace: space)
        }
    }

    private func fetchArchivedChildPageEntries(pageId: String, normalizedSpace space: String) async throws -> [ConfluencePageEntry] {
        let pages = try await self.fetchAll { cursor in
            try await self.client.listArchivedChildPages(pageId: pageId, cursor: cursor, limit: self.limit)
        }
        let filtered = try await self.filterRestricted(
            pages,
            restrictedIDsKey: "restrictedIDs/children/\(space)/\(pageId)/archived"
        ) { try await self.client.restrictedChildPageIDs(pageId: pageId, status: "archived", limiter: self.limiter) }
        return self.makeEntries(filtered)
    }

    // MARK: - Folders / Whiteboards (Cloud only)

    /// Sanitized, deduplicated folder and whiteboard entries that are **direct
    /// children of a page** (Cloud only; DC returns `.empty`). Confluence Cloud
    /// exposes both as page children via
    /// `GET /wiki/api/v2/pages/{id}/direct-children`; this extracts the `folder`-
    /// and `whiteboard`-typed entries from that mixed list.
    public func pageContainerEntries(pageId: String, spaceKey: String) async throws -> ConfluenceContainerEntries {
        guard client.config.edition.isCloud else { return .empty }
        let space = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
        return try await cached("pagecontainers/\(space)/\(pageId)/\(pageListVariant)", ttl: ttl.pages) {
            try await self.fetchPageContainerEntries(pageId: pageId)
        }
    }

    private func fetchPageContainerEntries(pageId: String) async throws -> ConfluenceContainerEntries {
        let children = try await fetchAll { cursor in
            try await self.client.listPageDirectChildren(pageId: pageId, cursor: cursor, limit: self.limit)
        }
        return ConfluenceContainerEntries(
            folders: makeFolderEntries(folders(in: children)),
            whiteboards: makeWhiteboardEntries(whiteboards(in: children))
        )
    }

    /// Combined children of a folder: pages, sub-folders and whiteboards (Cloud
    /// only; DC returns `.empty`). Entries are deduplicated within their own type;
    /// cross-type deduplication (ensuring no page name collides with a folder or
    /// whiteboard name in the same listing) is the caller's responsibility.
    public func folderChildren(folderId: String, spaceKey: String) async throws -> ConfluenceFolderChildrenResult {
        guard client.config.edition.isCloud else { return .empty }
        let space = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
        return try await cached("folderchildren/\(space)/\(folderId)/\(pageListVariant)", ttl: ttl.pages) {
            try await self.fetchFolderChildren(folderId: folderId, normalizedSpace: space)
        }
    }

    private func fetchFolderChildren(folderId: String, normalizedSpace space: String) async throws -> ConfluenceFolderChildrenResult {
        let allChildren = try await fetchAll { cursor in
            try await self.client.listFolderChildren(folderId: folderId, cursor: cursor, limit: self.limit)
        }
        return makeChildrenResult(allChildren)
    }

    /// Combined children of a whiteboard: pages, folders and sub-whiteboards
    /// (Cloud only; DC returns `.empty`). Whiteboards can act as containers in
    /// the Cloud content tree just like folders.
    public func whiteboardChildren(whiteboardId: String, spaceKey: String) async throws -> ConfluenceFolderChildrenResult {
        guard client.config.edition.isCloud else { return .empty }
        let space = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
        return try await cached("whiteboardchildren/\(space)/\(whiteboardId)/\(pageListVariant)", ttl: ttl.pages) {
            try await self.fetchWhiteboardChildren(whiteboardId: whiteboardId, normalizedSpace: space)
        }
    }

    private func fetchWhiteboardChildren(whiteboardId: String, normalizedSpace space: String) async throws -> ConfluenceFolderChildrenResult {
        let allChildren = try await fetchAll { cursor in
            try await self.client.listWhiteboardChildren(whiteboardId: whiteboardId, cursor: cursor, limit: self.limit)
        }
        return makeChildrenResult(allChildren)
    }

    /// Whiteboard metadata (Cloud only). The canvas content itself is not exposed
    /// by the REST API, so only descriptive metadata is available.
    public func whiteboard(id: String) async throws -> ConfluenceWhiteboard {
        try await cached("whiteboard/\(id)", ttl: ttl.pageDetail) {
            try await self.client.getWhiteboard(id: id)
        }
    }

    /// `true` when this mount can serve whiteboard canvases via Rovo MCP.
    public var whiteboardContentEnabled: Bool { rovoWhiteboards != nil }

    /// Floor for the whiteboard-canvas cache TTL. Rovo MCP is rate limited per
    /// site (and billed in Rovo credits), so a canvas is held far longer than
    /// ordinary REST detail responses.
    public static let whiteboardContentMinimumTTL: TimeInterval = 3600

    /// Whiteboard canvas rendered to text via Rovo MCP (Cloud only, opt-in).
    public func whiteboardContent(id: String) async throws -> String {
        guard let rovoWhiteboards else { throw AtlassianError.unsupported }
        let contentTTL = ttl.pageDetail <= 0
            ? ttl.pageDetail
            : max(ttl.pageDetail, PageDataSource.whiteboardContentMinimumTTL)
        // Single-flight the whole board→canvas resolution: the three whiteboard
        // files share one MCP fetch. Joiners share the leader's result and must
        // never cancel it (cancelling one waiter only fails that waiter, not the
        // shared task); unmount cancellation is handled by
        // `cancelBackgroundRefreshes()`.
        if let pending = pendingWhiteboardContentFetch[id] {
            return try await pending.value
        }
        let task = Task<String, Error> {
            let board = try await self.whiteboard(id: id)
            return try await self.cached("whiteboardcontent/\(id)", ttl: contentTTL) {
                try await rovoWhiteboards.content(for: board)
            }
        }
        pendingWhiteboardContentFetch[id] = task
        defer { pendingWhiteboardContentFetch[id] = nil }
        return try await task.value
    }

    private nonisolated func makeChildrenResult(_ children: [ConfluenceFolderChild]) -> ConfluenceFolderChildrenResult {
        let rawPages = children.compactMap { child -> ConfluencePage? in
            guard child.contentType == .page else { return nil }
            return ConfluencePage(
                id: child.id, title: child.title, spaceId: child.spaceId, parentId: child.parentId,
                version: child.version, authorId: child.authorId,
                createdAt: child.createdAt, webURL: child.webURL
            )
        }
        return ConfluenceFolderChildrenResult(
            pages: makeEntries(rawPages),
            folders: makeFolderEntries(folders(in: children)),
            whiteboards: makeWhiteboardEntries(whiteboards(in: children))
        )
    }

    private nonisolated func folders(in children: [ConfluenceFolderChild]) -> [ConfluenceFolder] {
        children.compactMap { child in
            guard child.contentType == .folder else { return nil }
            return ConfluenceFolder(id: child.id, title: child.title, spaceId: child.spaceId, parentId: child.parentId)
        }
    }

    private nonisolated func whiteboards(in children: [ConfluenceFolderChild]) -> [ConfluenceWhiteboard] {
        children.compactMap { child in
            guard child.contentType == .whiteboard else { return nil }
            return ConfluenceWhiteboard(
                id: child.id, title: child.title, spaceId: child.spaceId, parentId: child.parentId,
                authorId: child.authorId, createdAt: child.createdAt, webURL: child.webURL
            )
        }
    }

    public func page(id: String) async throws -> ConfluencePage {
        // Embed the body format in the cache key so toggling `renderMacros`
        // (storage <-> view) refetches instead of serving a stale representation.
        let format: ConfluenceBodyFormat = renderMacros ? .view : .storage
        return try await cached("page/\(id)/\(format.rawValue)", ttl: ttl.pageDetail) {
            try await self.client.getPage(id: id, bodyFormat: format)
        }
    }

    // MARK: - Comments / Attachments / Labels

    public func comments(pageId: String) async throws -> [ConfluenceComment] {
        try await cached("comments/\(pageId)", ttl: ttl.pageDetail) {
            try await self.fetchAll { cursor in
                try await self.client.listComments(pageId: pageId, cursor: cursor, limit: self.limit)
            }
        }
    }

    public func attachments(pageId: String) async throws -> [ConfluenceAttachment] {
        try await cached("attachments/\(pageId)", ttl: ttl.attachments) {
            try await self.fetchAll { cursor in
                try await self.client.listAttachments(pageId: pageId, cursor: cursor, limit: self.limit)
            }
        }
    }

    public func labels(pageId: String) async throws -> [ConfluenceLabel] {
        try await cached("labels/\(pageId)", ttl: ttl.pageDetail) {
            try await self.fetchAll { cursor in
                try await self.client.listLabels(pageId: pageId, cursor: cursor, limit: self.limit)
            }
        }
    }

    /// Serves a bounded byte window of an attachment.
    ///
    /// Delegates to the shared ``AttachmentByteCache``, which streams large files
    /// via HTTP `Range` and caches small files in memory (falling back to an
    /// in-memory copy if the server ignores `Range` and the body fits the inline
    /// cap). A `nil` range returns the whole file.
    public func downloadAttachment(_ attachment: ConfluenceAttachment, range: Range<Int>?) async throws -> Data {
        try await attachmentBytes.bytes(
            id: attachment.id,
            size: attachment.fileSize,
            range: range,
            rangeFetch: { [client, limiter] range in
                try await limiter.run { try await client.downloadAttachment(attachment, range: range) }
            }
        )
    }

    /// Returns the total byte size of an attachment whose listing metadata omits
    /// `fileSize`. The result is cached so the size probe runs at most once per
    /// TTL. Returns `nil` when the size cannot be determined.
    public func attachmentSize(_ attachment: ConfluenceAttachment) async throws -> Int? {
        if let known = attachment.fileSize { return known }
        let cacheKey = "attachment-size/\(attachment.id)"
        if let cached = await cache.get(cacheKey, as: Int.self) { return cached }
        let probed = try await limiter.run { try await self.client.attachmentSize(attachment) }
        if let probed { await cache.set(cacheKey, value: probed, ttl: ttl.attachmentBinary) }
        return probed
    }

    // MARK: - Naming

    /// Builds sanitized, deduplicated entries sorted by title. The dedup state
    /// is shared so `.html` siblings (built from `folderName`) never collide.
    private nonisolated func makeEntries(_ pages: [ConfluencePage]) -> [ConfluencePageEntry] {        var taken = Set<String>()
        return pages
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { page in
                let sanitized = FileNameSanitizer.sanitize(page.title)
                let name = FileNameSanitizer.deduplicate(sanitized, taken: &taken)
                return ConfluencePageEntry(folderName: name, page: page)
            }
    }

    /// Builds sanitized, deduplicated folder entries sorted by title.
    private nonisolated func makeFolderEntries(_ folders: [ConfluenceFolder]) -> [ConfluenceFolderEntry] {
        var taken = Set<String>()
        return folders
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { folder in
                let sanitized = FileNameSanitizer.sanitize(folder.title)
                let name = FileNameSanitizer.deduplicate(sanitized, taken: &taken)
                return ConfluenceFolderEntry(folderName: name, folder: folder)
            }
    }

    /// Builds sanitized, deduplicated whiteboard entries sorted by title.
    private nonisolated func makeWhiteboardEntries(_ whiteboards: [ConfluenceWhiteboard]) -> [ConfluenceWhiteboardEntry] {
        var taken = Set<String>()
        return whiteboards
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { whiteboard in
                let sanitized = FileNameSanitizer.sanitize(whiteboard.title)
                let name = FileNameSanitizer.deduplicate(sanitized, taken: &taken)
                return ConfluenceWhiteboardEntry(folderName: name, whiteboard: whiteboard)
            }
    }

    /// Filters pages based on restriction status. For Cloud, calls a scoped v1
    /// API endpoint to fetch only the restricted IDs within the current listing
    /// (root pages or direct children of one parent) — never the whole space.
    /// For DC, uses the inline `hasRestrictions` flag set via `expand`.
    /// Returns `pages` unchanged when `includeRestricted` is `true`.
    private func filterRestricted(
        _ pages: [ConfluencePage],
        restrictedIDsKey: String,
        fetchRestrictedIDs: @Sendable @escaping () async throws -> Set<String>
    ) async throws -> [ConfluencePage] {
        guard !includeRestricted else { return pages }
        // An empty listing has nothing to filter; skip the restricted-ID fetch
        // entirely so empty spaces/parents don't trigger a needless API request
        // (and cache entry) on Cloud.
        guard !pages.isEmpty else { return pages }
        if client.config.edition.isCloud {
            let ids = try await restrictedIDsSingleFlight(
                cacheKey: restrictedIDsKey,
                fetch: fetchRestrictedIDs
            )
            return ids.isEmpty ? pages : pages.filter { !ids.contains($0.id) }
        } else {
            return pages.filter { $0.hasRestrictions != true }
        }
    }

    /// Returns restricted Cloud page IDs for one directory listing, using
    /// single-flight deduplication so that concurrent background pre-caching
    /// tasks share one in-flight API call per cache key.
    private func restrictedIDsSingleFlight(
        cacheKey: String,
        fetch rawFetch: @Sendable @escaping () async throws -> Set<String>
    ) async throws -> Set<String> {
        // Single-flight + cache only; per-page rate limiting is applied inside
        // the client's paginated restricted-ID fetch so each page request honours
        // 429 / server-error retries and backoff independently.
        let fetch = rawFetch
        if let fresh = await cache.get(cacheKey, as: Set<String>.self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: Set<String>.self) {
            scheduleRefresh(cacheKey, ttl: ttl.pages, fetch: fetch)
            return stale
        }
        // Join an existing in-flight fetch if there is one. Joiners share the
        // leader's result and must never cancel it: it is a single-flight task
        // that other callers depend on, and the leader owns caching + cleanup.
        if let pending = pendingRestrictedIDsFetch[cacheKey] {
            return try await pending.value
        }
        // Start a new fetch and register it so other concurrent callers can join.
        let task = Task<Set<String>, Error>(operation: fetch)
        pendingRestrictedIDsFetch[cacheKey] = task
        // Clear the pending entry on every exit path. `defer` runs after the
        // `return ids` value (and therefore after `cache.set`) is evaluated, so
        // the entry stays registered until the cache is populated — a concurrent
        // caller arriving during `cache.set` still joins this fetch instead of
        // starting a duplicate one (single-flight guarantee). The shared task is
        // never cancelled here; unmount cancellation is handled separately by
        // `cancelBackgroundRefreshes()`.
        defer { pendingRestrictedIDsFetch[cacheKey] = nil }
        let ids = try await task.value
        await cache.set(cacheKey, value: ids, ttl: ttl.pages)
        return ids
    }

    // MARK: - Generic cache + pagination

    private func cached<T: Codable & Sendable>(
        _ key: String,
        ttl: TimeInterval,
        fetch: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        if let fresh = await cache.get(key, as: T.self) { return fresh }
        if let stale = await cache.getStale(key, as: T.self) {
            scheduleRefresh(key, ttl: ttl, fetch: fetch)
            return stale
        }
        let value = try await fetch()
        await cache.set(key, value: value, ttl: ttl)
        return value
    }

    private func scheduleRefresh<T: Codable & Sendable>(
        _ key: String,
        ttl: TimeInterval,
        fetch: @Sendable @escaping () async throws -> T
    ) {
        guard !refreshing.contains(key) else { return }
        refreshing.insert(key)
        refreshTasks[key] = Task {
            defer { self.clearRefreshing(key) }
            if let value = try? await fetch() {
                await self.cache.set(key, value: value, ttl: ttl)
            }
        }
    }

    private func clearRefreshing(_ key: String) {
        refreshing.remove(key)
        refreshTasks[key] = nil
    }

    /// Cancels every in-flight background refresh (and any single-flight
    /// restricted-ID fetch). Called from `ConfluenceVolume`'s `unmount` so
    /// stale-while-revalidate / periodic refreshes cannot keep issuing network
    /// requests — or retain this actor and its dependencies — after the volume
    /// is gone. URLSession's async API is cancellation-aware, so cancelling
    /// propagates to any request currently on the wire.
    ///
    /// `async` so the attachment cache cleanup completes before this returns
    /// (and therefore before `unmount` replies), rather than racing it on an
    /// unstructured `Task`.
    public func cancelBackgroundRefreshes() async {
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        refreshing.removeAll()
        for task in pendingRestrictedIDsFetch.values { task.cancel() }
        pendingRestrictedIDsFetch.removeAll()
        for task in pendingWhiteboardContentFetch.values { task.cancel() }
        pendingWhiteboardContentFetch.removeAll()
        // Await so any in-flight attachment download is cancelled and the
        // in-memory attachment cache is cleared before unmount reports completion.
        await attachmentBytes.clear()
    }

    /// Follows the pagination cursor until exhausted (bounded for safety).
    private func fetchAll<Element: Sendable>(
        _ page: @Sendable (_ cursor: String?) async throws -> ConfluencePageList<Element>
    ) async throws -> [Element] {
        var items: [Element] = []
        var cursor: String? = nil
        var guardCount = 0
        repeat {
            let pageCursor = cursor
            let result = try await limiter.run { try await page(pageCursor) }
            items.append(contentsOf: result.items)
            cursor = result.nextCursor
            guardCount += 1
        } while cursor != nil && guardCount < 1000
        if cursor != nil {
            logger.warning("fetchAll: pagination guard limit (1000 pages) reached; \(items.count) items collected so far. Some items may be missing.")
        }
        return items
    }
}
