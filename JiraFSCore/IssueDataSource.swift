import Foundation
import JiraAPI

/// High-level read-only data source backing the FSKit volume.
///
/// Combines a `JiraClient` with `CacheManager` so the volume sees a
/// unified, cache-aware view.
public actor IssueDataSource {
    public let client: any JiraClient
    public let cache: CacheManager
    public let ttl: Configuration.CacheTTLConfig
    public let maxResults: Int
    /// Project key allowlist. `nil` = all projects; non-empty = only listed keys.
    public let allowedProjectKeys: [String]?
    private let limiter: RateLimiter

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

    public func projects() async throws -> [JiraProject] {
        if let cached = await cache.get("projects", as: [JiraProject].self) {
            return cached
        }
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

    public func project(key: String) async throws -> JiraProject {
        let cacheKey = "project/\(key)"
        if let cached = await cache.get(cacheKey, as: JiraProject.self) {
            return cached
        }
        let value = try await limiter.run { [client] in
            try await client.getProject(key: key)
        }
        await cache.set(cacheKey, value: value, ttl: ttl.projects)
        return value
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
        if let cached = await cache.get(cacheKey, as: [String].self) {
            return cached
        }

        let jql = "project = \(key) ORDER BY created DESC"

        // Fetch first page to detect edition and obtain total if available.
        // fields: [] → JIRA returns only the top-level "key" (no fields body),
        // which is all we need here. Full issue data is fetched lazily on demand.
        let first = try await limiter.run { [client] in
            try await client.searchIssues(jql: jql, nextPageToken: nil, maxResults: maxResults, fields: [])
        }
        var collected = first.issues.map(\.key)

        if let total = first.total, let startAt = first.startAt, total > collected.count {
            // Server edition: all remaining pages can be calculated upfront and
            // fetched concurrently because the offset is a simple integer.
            let extra = try await fetchRemainingPagesParallel(
                jql: jql,
                fetchedCount: startAt + collected.count,
                total: total
            )
            collected.append(contentsOf: extra)
        } else {
            // Cloud edition: sequential cursor walk.
            var pageToken = first.nextPageToken
            while let token = pageToken {
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

    /// Fetches pages `fetchedCount..<total` (step `maxResults`) in parallel,
    /// with a concurrency cap to avoid triggering JIRA rate limiting.
    private func fetchRemainingPagesParallel(jql: String, fetchedCount: Int, total: Int) async throws -> [String] {
        let offsets = stride(from: fetchedCount, to: total, by: maxResults).map { Int($0) }
        guard !offsets.isEmpty else { return [] }
        // Cap concurrent requests to avoid hitting server-side rate limits.
        let concurrencyLimit = 20

        let pages = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var inFlight = 0
            var offsetIterator = offsets.makeIterator()

            // Seed up to concurrencyLimit tasks.
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
            // As each task finishes, launch the next pending offset.
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

    public func issue(key: String) async throws -> JiraIssue {
        let cacheKey = "issue/\(key)"
        if let cached = await cache.get(cacheKey, as: JiraIssue.self) {
            return cached
        }
        let value = try await limiter.run { [client] in
            try await client.getIssue(key: key)
        }
        await cache.set(cacheKey, value: value, ttl: ttl.issueDetail)
        return value
    }

    public func comments(issueKey: String) async throws -> [JiraComment] {
        let cacheKey = "comments/\(issueKey)"
        if let cached = await cache.get(cacheKey, as: [JiraComment].self) {
            return cached
        }
        let value = try await limiter.run { [client] in
            try await client.listComments(issueKey: issueKey)
        }
        await cache.set(cacheKey, value: value, ttl: ttl.issueDetail)
        return value
    }

    public func attachments(issueKey: String) async throws -> [JiraAttachment] {
        let cacheKey = "attachments/\(issueKey)"
        if let cached = await cache.get(cacheKey, as: [JiraAttachment].self) {
            return cached
        }
        let value = try await limiter.run { [client] in
            try await client.listAttachments(issueKey: issueKey)
        }
        await cache.set(cacheKey, value: value, ttl: ttl.attachments)
        return value
    }

    public func attachmentData(_ attachment: JiraAttachment) async throws -> Data {
        let cacheKey = "attachment-bin/\(attachment.id)"
        if let cached = await cache.get(cacheKey, as: Data.self) {
            return cached
        }
        let value = try await limiter.run { [client] in
            try await client.downloadAttachment(attachment, range: nil)
        }
        await cache.set(cacheKey, value: value, ttl: ttl.attachmentBinary)
        return value
    }

    public func synchronize() async {
        await cache.synchronize()
    }
}
