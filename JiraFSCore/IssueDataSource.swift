import Foundation
import JiraAPI

/// High-level read-only data source backing the FSKit volume.
///
/// Combines a `JiraClient` with `CacheManager` so the volume sees a
/// unified, cache-aware view.
///
/// ## Stale-while-revalidate
/// For every resource type (projects, issue keys, issue detail, comments,
/// attachments) the lookup order is:
///   1. **Fresh cache** → return immediately, no network.
///   2. **Stale cache** → return immediately (Finder never spins), schedule
///      a background `Task` to refresh the cache for the next access.
///   3. **No cache** → synchronous API fetch (first-time only).
///
/// A `refreshing` set guards against duplicate in-flight background fetches
/// for the same cache key.
public actor IssueDataSource {
    public let client: any JiraClient
    public let cache: CacheManager
    public let ttl: Configuration.CacheTTLConfig
    public let maxResults: Int
    /// Project key allowlist. `nil` = all projects; non-empty = only listed keys.
    public let allowedProjectKeys: [String]?
    private let limiter: RateLimiter

    /// Cache keys for which a background refresh is already in flight.
    private var refreshing: Set<String> = []

    public init(
        client: any JiraClient,
        cache: CacheManager = CacheManager(),
        ttl: Configuration.CacheTTLConfig = .default,
        maxResults: Int = 100,
        allowedProjectKeys: [String]? = nil,
        limiter: RateLimiter = RateLimiter()
    ) {
        self.client = client
        self.cache = cache
        self.ttl = ttl
        self.maxResults = maxResults
        self.allowedProjectKeys = allowedProjectKeys
        self.limiter = limiter
    }

    // MARK: - Public API

    public func projects() async throws -> [JiraProject] {
        let cacheKey = "projects"
        if let fresh = await cache.get(cacheKey, as: [JiraProject].self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: [JiraProject].self) {
            scheduleRefresh(cacheKey) { await self.bgRefreshProjects() }
            return stale
        }
        return try await fetchAndCacheProjects()
    }

    public func project(key: String) async throws -> JiraProject {
        let cacheKey = "project/\(key)"
        if let fresh = await cache.get(cacheKey, as: JiraProject.self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: JiraProject.self) {
            scheduleRefresh(cacheKey) { await self.bgRefreshProject(key: key) }
            return stale
        }
        return try await fetchAndCacheProject(key: key)
    }

    /// Returns all issue keys for a JIRA project.
    ///
    /// **Server edition** (response includes `total` + numeric `startAt`):
    /// after the first page, all remaining pages are fetched in parallel via
    /// `TaskGroup`, so even a 1 000-issue project completes in roughly one
    /// round-trip (≈ 1.3 s instead of 20 × 1.3 s sequentially).
    ///
    /// **Cloud edition** (cursor-based `nextPageToken`): pages are fetched
    /// sequentially as the token for page N+1 is only available after page N.
    public func issueKeys(forProject key: String) async throws -> [String] {
        let cacheKey = "issues/\(key)"
        if let fresh = await cache.get(cacheKey, as: [String].self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: [String].self) {
            scheduleRefresh(cacheKey) { await self.bgRefreshIssueKeys(project: key) }
            return stale
        }
        return try await fetchAndCacheIssueKeys(forProject: key)
    }

    public func issue(key: String) async throws -> JiraIssue {
        let cacheKey = "issue/\(key)"
        if let fresh = await cache.get(cacheKey, as: JiraIssue.self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: JiraIssue.self) {
            scheduleRefresh(cacheKey) { await self.bgRefreshIssue(key: key) }
            return stale
        }
        return try await fetchAndCacheIssue(key: key)
    }

    public func comments(issueKey: String) async throws -> [JiraComment] {
        let cacheKey = "comments/\(issueKey)"
        if let fresh = await cache.get(cacheKey, as: [JiraComment].self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: [JiraComment].self) {
            scheduleRefresh(cacheKey) { await self.bgRefreshComments(issueKey: issueKey) }
            return stale
        }
        return try await fetchAndCacheComments(issueKey: issueKey)
    }

    public func attachments(issueKey: String) async throws -> [JiraAttachment] {
        let cacheKey = "attachments/\(issueKey)"
        if let fresh = await cache.get(cacheKey, as: [JiraAttachment].self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: [JiraAttachment].self) {
            scheduleRefresh(cacheKey) { await self.bgRefreshAttachments(issueKey: issueKey) }
            return stale
        }
        return try await fetchAndCacheAttachments(issueKey: issueKey)
    }

    public func attachmentData(_ attachment: JiraAttachment) async throws -> Data {
        let cacheKey = "attachment-bin/\(attachment.id)"
        if let cached = await cache.get(cacheKey, as: Data.self) { return cached }
        let value = try await limiter.run { [client] in
            try await client.downloadAttachment(attachment, range: nil)
        }
        await cache.set(cacheKey, value: value, ttl: ttl.attachmentBinary)
        return value
    }

    public func synchronize() async {
        await cache.synchronize()
    }

    /// Returns a mapping of custom field id → display name (e.g. "customfield_10016" → "Story Points").
    /// Result is cached with the projects TTL and lazily fetched on first call.
    public func fieldNames() async -> [String: String] {
        let cacheKey = "fieldNames"
        if let fresh = await cache.get(cacheKey, as: [String: String].self) { return fresh }
        if let stale = await cache.getStale(cacheKey, as: [String: String].self) {
            scheduleRefresh(cacheKey) { await self.bgRefreshFieldNames() }
            return stale
        }
        guard let fields = try? await limiter.run({ [client] in try await client.listFields() }) else { return [:] }
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.name) })
        await cache.set(cacheKey, value: map, ttl: ttl.projects)
        return map
    }

    /// Pre-warm the in-memory cache from disk so Finder browsing is fast
    /// immediately after mount. Loads projects list and all issue key lists
    /// sequentially in the background; individual issue details remain lazy.
    public func warmUp() async {
        guard let projects = try? await self.projects() else { return }
        for project in projects {
            _ = try? await self.issueKeys(forProject: project.key)
        }
    }

    // MARK: - Background refresh scheduling

    /// Starts a background refresh task for `key` if one is not already running.
    private func scheduleRefresh(_ key: String, task: @escaping @Sendable () async -> Void) {
        guard !refreshing.contains(key) else { return }
        refreshing.insert(key)
        Task { await task() }
    }

    private func finishRefresh(_ key: String) { refreshing.remove(key) }

    // MARK: - Background refresh tasks

    private func bgRefreshProjects() async {
        _ = try? await fetchAndCacheProjects()
        finishRefresh("projects")
    }

    private func bgRefreshProject(key: String) async {
        _ = try? await fetchAndCacheProject(key: key)
        finishRefresh("project/\(key)")
    }

    private func bgRefreshIssueKeys(project: String) async {
        _ = try? await fetchAndCacheIssueKeys(forProject: project)
        finishRefresh("issues/\(project)")
    }

    private func bgRefreshIssue(key: String) async {
        _ = try? await fetchAndCacheIssue(key: key)
        finishRefresh("issue/\(key)")
    }

    private func bgRefreshComments(issueKey: String) async {
        _ = try? await fetchAndCacheComments(issueKey: issueKey)
        finishRefresh("comments/\(issueKey)")
    }

    private func bgRefreshAttachments(issueKey: String) async {
        _ = try? await fetchAndCacheAttachments(issueKey: issueKey)
        finishRefresh("attachments/\(issueKey)")
    }

    private func bgRefreshFieldNames() async {
        let key = "fieldNames"
        guard let fields = try? await limiter.run({ [client] in try await client.listFields() }) else {
            finishRefresh(key); return
        }
        let map = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.name) })
        await cache.set(key, value: map, ttl: ttl.projects)
        finishRefresh(key)
    }

    // MARK: - Fetch + cache (synchronous path)

    private func fetchAndCacheProjects() async throws -> [JiraProject] {
        let value = try await limiter.run { [client] in
            try await client.listProjects()
        }
        let filtered: [JiraProject]
        if let allowed = allowedProjectKeys, !allowed.isEmpty {
            let upper = allowed.map { $0.uppercased() }
            filtered = value.filter { upper.contains($0.key.uppercased()) }
        } else {
            filtered = value
        }
        await cache.set("projects", value: filtered, ttl: ttl.projects)
        return filtered
    }

    private func fetchAndCacheProject(key: String) async throws -> JiraProject {
        let value = try await limiter.run { [client] in
            try await client.getProject(key: key)
        }
        await cache.set("project/\(key)", value: value, ttl: ttl.projects)
        return value
    }

    private func fetchAndCacheIssueKeys(forProject key: String) async throws -> [String] {
        let cacheKey = "issues/\(key)"
        let jql = "project = \(key) ORDER BY created DESC"

        let first = try await limiter.run { [client] in
            try await client.searchIssues(jql: jql, nextPageToken: nil, maxResults: maxResults, fields: [])
        }
        var collected = first.issues.map(\.key)

        if let total = first.total, let startAt = first.startAt, total > collected.count {
            let extra = try await fetchRemainingPagesParallel(
                jql: jql,
                fetchedCount: startAt + collected.count,
                total: total
            )
            collected.append(contentsOf: extra)
        } else {
            var pageToken = first.nextPageToken
            while let token = pageToken {
                try Task.checkCancellation()
                let result = try await limiter.run { [client] in
                    try await client.searchIssues(jql: jql, nextPageToken: token, maxResults: maxResults, fields: [])
                }
                collected.append(contentsOf: result.issues.map(\.key))
                pageToken = result.nextPageToken
                if result.issues.isEmpty { break }
            }
        }

        await cache.set(cacheKey, value: collected, ttl: ttl.issues)
        return collected
    }

    private func fetchAndCacheIssue(key: String) async throws -> JiraIssue {
        let value = try await limiter.run { [client] in
            try await client.getIssue(key: key)
        }
        await cache.set("issue/\(key)", value: value, ttl: ttl.issueDetail)
        return value
    }

    private func fetchAndCacheComments(issueKey: String) async throws -> [JiraComment] {
        let value = try await limiter.run { [client] in
            try await client.listComments(issueKey: issueKey)
        }
        await cache.set("comments/\(issueKey)", value: value, ttl: ttl.issueDetail)
        return value
    }

    private func fetchAndCacheAttachments(issueKey: String) async throws -> [JiraAttachment] {
        let value = try await limiter.run { [client] in
            try await client.listAttachments(issueKey: issueKey)
        }
        await cache.set("attachments/\(issueKey)", value: value, ttl: ttl.attachments)
        return value
    }
    // MARK: - Server parallel page fetch

    /// Fetches pages `fetchedCount..<total` (step `maxResults`) in parallel,
    /// with a concurrency cap to avoid triggering JIRA rate limiting.
    private func fetchRemainingPagesParallel(jql: String, fetchedCount: Int, total: Int) async throws -> [String] {
        let offsets = stride(from: fetchedCount, to: total, by: maxResults).map { Int($0) }
        guard !offsets.isEmpty else { return [] }
        let concurrencyLimit = 20

        let pages = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var inFlight = 0
            var offsetIterator = offsets.makeIterator()

            while inFlight < concurrencyLimit, let offset = offsetIterator.next() {
                let capturedOffset = offset
                group.addTask {
                    let result = try await self.limiter.run { [self] in
                        try await self.client.searchIssues(
                            jql: jql,
                            nextPageToken: String(capturedOffset),
                            maxResults: self.maxResults,
                            fields: []
                        )
                    }
                    return (capturedOffset, result.issues.map(\.key))
                }
                inFlight += 1
            }

            var all: [(Int, [String])] = []
            for try await page in group {
                all.append(page)
                if let offset = offsetIterator.next() {
                    let capturedOffset = offset
                    group.addTask {
                        let result = try await self.limiter.run { [self] in
                            try await self.client.searchIssues(
                                jql: jql,
                                nextPageToken: String(capturedOffset),
                                maxResults: self.maxResults,
                                fields: []
                            )
                        }
                        return (capturedOffset, result.issues.map(\.key))
                    }
                }
            }
            return all.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        return pages
    }
}
