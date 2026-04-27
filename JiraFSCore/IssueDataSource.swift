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
    private let limiter: RateLimiter

    public init(
        client: any JiraClient,
        cache: CacheManager = CacheManager(),
        ttl: Configuration.CacheTTLConfig = .default,
        maxResults: Int = 50,
        limiter: RateLimiter = RateLimiter()
    ) {
        self.client = client
        self.cache = cache
        self.ttl = ttl
        self.maxResults = maxResults
        self.limiter = limiter
    }

    public func projects() async throws -> [JiraProject] {
        if let cached = await cache.get("projects", as: [JiraProject].self) {
            return cached
        }
        let value = try await limiter.run { [client] in
            try await client.listProjects()
        }
        await cache.set("projects", value: value, ttl: ttl.projects)
        return value
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

    public func issueKeys(forProject key: String) async throws -> [String] {
        let cacheKey = "issues/\(key)"
        if let cached = await cache.get(cacheKey, as: [String].self) {
            return cached
        }
        var collected: [String] = []
        var startAt = 0
        let pageSize = maxResults
        while true {
            let pageStart = startAt
            let result = try await limiter.run { [client] in
                try await client.searchIssues(jql: "project = \(key) ORDER BY created DESC", startAt: pageStart, maxResults: pageSize)
            }
            collected.append(contentsOf: result.issues.map(\.key))
            startAt += result.issues.count
            if startAt >= result.total || result.issues.isEmpty { break }
        }
        await cache.set(cacheKey, value: collected, ttl: ttl.issues)
        return collected
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
