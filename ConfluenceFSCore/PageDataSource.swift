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
    private let limiter: RateLimiter
    private let logger = AtlassianLog.logger("confluence-datasource")

    private var refreshing: Set<String> = []
    /// Single-flight guard for Cloud restricted-page-ID fetches. Prevents N
    /// concurrent tasks from each initiating the same directory-scoped
    /// restricted-ID fetch (root pages of a space, or one parent's children)
    /// when the background pre-caching fills child-page entries in parallel.
    private var pendingRestrictedIDsFetch: [String: Task<Set<String>, Error>] = [:]

    public init(
        client: any ConfluenceClient,
        cache: CacheManager = CacheManager(),
        ttl: ConfluenceConfiguration.CacheTTLConfig = .default,
        limit: Int = 100,
        allowedSpaceKeys: [String]? = nil,
        includeArchived: Bool = false,
        includeRestricted: Bool = false,
        limiter: RateLimiter = RateLimiter()
    ) {
        self.client = client
        self.cache = cache
        self.ttl = ttl
        self.limit = limit
        self.includeArchived = includeArchived
        self.includeRestricted = includeRestricted
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
            let pages = try await self.fetchAll { cursor in
                try await self.client.listRootPages(space: space, cursor: cursor, limit: self.limit)
            }
            let filtered = try await self.filterRestricted(
                pages,
                restrictedIDsKey: "restrictedIDs/root/\(space.key)/current"
            ) { try await self.client.restrictedRootPageIDs(spaceKey: space.key, status: "current") }
            return self.makeEntries(filtered)
        }
    }

    /// Sanitized, deduplicated archived root-page entries. Only fetched when `includeArchived` is true.
    public func archivedRootPageEntries(space: ConfluenceSpace) async throws -> [ConfluencePageEntry] {
        guard includeArchived else { return [] }
        return try await cached("archivedRootPages/\(space.key)/\(pageListVariant)", ttl: ttl.pages) {
            let pages = try await self.fetchAll { cursor in
                try await self.client.listArchivedRootPages(space: space, cursor: cursor, limit: self.limit)
            }
            let filtered = try await self.filterRestricted(
                pages,
                restrictedIDsKey: "restrictedIDs/root/\(space.key)/archived"
            ) { try await self.client.restrictedRootPageIDs(spaceKey: space.key, status: "archived") }
            return self.makeEntries(filtered)
        }
    }

    /// Sanitized, deduplicated child-page entries for a page, sorted by title.
    public func childPageEntries(pageId: String, spaceKey: String) async throws -> [ConfluencePageEntry] {
        let space = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
        return try await cached("childpages/\(space)/\(pageId)/\(pageListVariant)", ttl: ttl.pages) {
            let pages = try await self.fetchAll { cursor in
                try await self.client.listChildPages(pageId: pageId, cursor: cursor, limit: self.limit)
            }
            let filtered = try await self.filterRestricted(
                pages,
                restrictedIDsKey: "restrictedIDs/children/\(space)/\(pageId)/current"
            ) { try await self.client.restrictedChildPageIDs(pageId: pageId, status: "current") }
            return self.makeEntries(filtered)
        }
    }

    /// Sanitized, deduplicated archived child-page entries. Only fetched when `includeArchived` is true.
    public func archivedChildPageEntries(pageId: String, spaceKey: String) async throws -> [ConfluencePageEntry] {
        guard includeArchived else { return [] }
        let space = spaceKey.trimmingCharacters(in: .whitespaces).uppercased()
        return try await cached("archivedChildPages/\(space)/\(pageId)/\(pageListVariant)", ttl: ttl.pages) {
            let pages = try await self.fetchAll { cursor in
                try await self.client.listArchivedChildPages(pageId: pageId, cursor: cursor, limit: self.limit)
            }
            let filtered = try await self.filterRestricted(
                pages,
                restrictedIDsKey: "restrictedIDs/children/\(space)/\(pageId)/archived"
            ) { try await self.client.restrictedChildPageIDs(pageId: pageId, status: "archived") }
            return self.makeEntries(filtered)
        }
    }

    /// Full page including the storage-format body.
    public func page(id: String) async throws -> ConfluencePage {
        try await cached("page/\(id)", ttl: ttl.pageDetail) {
            try await self.client.getPage(id: id, bodyFormat: .storage)
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

    public func downloadAttachment(_ attachment: ConfluenceAttachment, range: Range<Int>?) async throws -> Data {
        // Cache only full-file reads; partial reads (range != nil) are not cached.
        guard range == nil else {
            return try await limiter.run { try await self.client.downloadAttachment(attachment, range: range) }
        }
        let cacheKey = "attachment-bin/\(attachment.id)"
        if let cached = await cache.get(cacheKey, as: Data.self) { return cached }
        let value = try await limiter.run { try await self.client.downloadAttachment(attachment, range: nil) }
        await cache.set(cacheKey, value: value, ttl: ttl.attachmentBinary)
        return value
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
        fetch: @Sendable @escaping () async throws -> Set<String>
    ) async throws -> Set<String> {
        if let fresh = await cache.get(cacheKey, as: Set<String>.self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: Set<String>.self) {
            scheduleRefresh(cacheKey, ttl: ttl.pages, fetch: fetch)
            return stale
        }
        // Join an existing in-flight fetch if there is one.
        if let pending = pendingRestrictedIDsFetch[cacheKey] {
            return try await pending.value
        }
        // Start a new fetch and register it so other concurrent callers can join.
        let task = Task<Set<String>, Error>(operation: fetch)
        pendingRestrictedIDsFetch[cacheKey] = task
        do {
            let ids = try await task.value
            pendingRestrictedIDsFetch[cacheKey] = nil
            await cache.set(cacheKey, value: ids, ttl: ttl.pages)
            return ids
        } catch {
            pendingRestrictedIDsFetch[cacheKey] = nil
            throw error
        }
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
        Task {
            defer { Task { await self.clearRefreshing(key) } }
            if let value = try? await fetch() {
                await self.cache.set(key, value: value, ttl: ttl)
            }
        }
    }

    private func clearRefreshing(_ key: String) {
        refreshing.remove(key)
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
