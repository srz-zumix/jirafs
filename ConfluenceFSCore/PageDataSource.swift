import Foundation
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
    private let limiter: RateLimiter

    private var refreshing: Set<String> = []

    public init(
        client: any ConfluenceClient,
        cache: CacheManager = CacheManager(),
        ttl: ConfluenceConfiguration.CacheTTLConfig = .default,
        limit: Int = 100,
        allowedSpaceKeys: [String]? = nil,
        includeArchived: Bool = false,
        limiter: RateLimiter = RateLimiter()
    ) {
        self.client = client
        self.cache = cache
        self.ttl = ttl
        self.limit = limit
        self.includeArchived = includeArchived
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
        try await cached("spaces", ttl: ttl.spaces) {
            var all = try await self.fetchAll { cursor in
                try await self.client.listSpaces(cursor: cursor, limit: self.limit)
            }
            if let allowed = self.allowedSpaceKeys {
                let set = Set(allowed)
                all = all.filter { set.contains($0.key.uppercased()) }
            }
            return all.sorted { $0.key < $1.key }
        }
    }

    public func space(key: String) async throws -> ConfluenceSpace? {
        try await spaces().first { $0.key == key }
    }

    // MARK: - Pages

    /// Sanitized, deduplicated root-page entries for a space, sorted by title.
    public func rootPageEntries(space: ConfluenceSpace) async throws -> [ConfluencePageEntry] {
        try await cached("rootpages/\(space.key)", ttl: ttl.pages) {
            let pages = try await self.fetchAll { cursor in
                try await self.client.listRootPages(space: space, cursor: cursor, limit: self.limit)
            }
            return self.makeEntries(pages)
        }
    }

    /// Sanitized, deduplicated archived root-page entries. Only fetched when `includeArchived` is true.
    public func archivedRootPageEntries(space: ConfluenceSpace) async throws -> [ConfluencePageEntry] {
        guard includeArchived else { return [] }
        return try await cached("archivedRootPages/\(space.key)", ttl: ttl.pages) {
            let pages = try await self.fetchAll { cursor in
                try await self.client.listArchivedRootPages(space: space, cursor: cursor, limit: self.limit)
            }
            return self.makeEntries(pages)
        }
    }

    /// Sanitized, deduplicated child-page entries for a page, sorted by title.
    public func childPageEntries(pageId: String) async throws -> [ConfluencePageEntry] {
        try await cached("childpages/\(pageId)", ttl: ttl.pages) {
            let pages = try await self.fetchAll { cursor in
                try await self.client.listChildPages(pageId: pageId, cursor: cursor, limit: self.limit)
            }
            return self.makeEntries(pages)
        }
    }

    /// Sanitized, deduplicated archived child-page entries. Only fetched when `includeArchived` is true.
    public func archivedChildPageEntries(pageId: String) async throws -> [ConfluencePageEntry] {
        guard includeArchived else { return [] }
        return try await cached("archivedChildPages/\(pageId)", ttl: ttl.pages) {
            let pages = try await self.fetchAll { cursor in
                try await self.client.listArchivedChildPages(pageId: pageId, cursor: cursor, limit: self.limit)
            }
            return self.makeEntries(pages)
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
        try await client.downloadAttachment(attachment, range: range)
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
        return items
    }
}
