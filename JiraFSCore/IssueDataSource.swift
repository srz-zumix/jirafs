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

    /// In-flight deduplication for the projects fetch.
    /// When warmUp and a Finder `enumerateDirectory` both call `projects()` on
    /// a cold cache simultaneously (which is the common case on first mount),
    /// both would otherwise issue an identical `listProjects()` network request
    /// independently.  Storing the in-flight `Task` here lets the second caller
    /// piggy-back on the first request instead of issuing a duplicate.
    private var pendingProjectsFetch: Task<[JiraProject], Error>?

    /// In-flight deduplication for per-project issue-key fetches.
    /// Same rationale as `pendingProjectsFetch`: warmUp's `issueKeys()` and a
    /// concurrent Finder `enumerateDirectory` of the same issues/ directory
    /// should share one network round-trip instead of each issuing their own.
    private var pendingIssueKeysFetch: [String: Task<[String], Error>] = [:]

    /// Called on the actor's executor after every successful background refresh of
    /// the issue key list for a project. The parameter is the project key.
    /// `JiraVolume` uses this to update the directory's `cachedMTime` so that
    /// Finder's kqueue watcher fires and the directory listing auto-refreshes.
    /// Fired regardless of whether the key set actually changed, to ensure Finder
    /// never shows a stale partial listing.
    public var onIssueKeysRefreshed: (@Sendable (String) -> Void)?

    /// Sets the handler invoked after every successful background refresh of the
    /// issue key list for any project. This is an async setter because
    /// `IssueDataSource` is an actor — the property can only be mutated on the
    /// actor's executor.
    public func setIssueKeysRefreshedHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onIssueKeysRefreshed = handler
    }

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
        // Normalize: trim whitespace, uppercase, de-duplicate, then nil-ify if empty.
        // This ensures keys from manual config.json edits (or any external source)
        // match JIRA's canonical uppercase project keys regardless of how they were stored.
        if let raw = allowedProjectKeys {
            var seen = Set<String>()
            let normalized = raw
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            self.allowedProjectKeys = normalized.isEmpty ? nil : normalized
        } else {
            self.allowedProjectKeys = nil
        }
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

    /// Schedule background API fetches for all known projects immediately
    /// after `warmUp()`. The cache at this point may be stale disk data;
    /// this call ensures the in-memory cache is populated with fresh network
    /// data as soon as possible after mount, without blocking the reply.
    ///
    /// Skips projects whose issue-key list is already fresh in L1 — this avoids
    /// a redundant round-trip when `warmUp()` just performed a cold-cache fetch
    /// and stored fresh data moments ago.
    public func postWarmUpRefresh() async {
        guard let projects = try? await self.projects() else { return }
        for project in projects {
            let key = "issues/\(project.key)"
            // cache.get() returns non-nil only for unexpired (fresh) entries.
            // If the data is fresh, warmUp() already did the network fetch;
            // scheduling another refresh here would be a wasted API call.
            if await cache.get(key, as: [String].self) != nil { continue }
            scheduleRefresh(key) { await self.bgRefreshIssueKeys(project: project.key) }
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
        let cacheKey = "issues/\(project)"
        guard (try? await fetchAndCacheIssueKeys(forProject: project)) != nil else {
            finishRefresh(cacheKey); return
        }
        finishRefresh(cacheKey)
        // Always notify so Finder re-enumerates after every refresh cycle.
        // Without this, a partial initial enumeration (large directory) would
        // leave Finder with a stale incomplete listing if no keys were added
        // or removed since the last refresh.
        onIssueKeysRefreshed?(project)
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
        // Single-flight deduplication: if a fetch is already in progress, join
        // it rather than starting a second identical network request.
        if let pending = pendingProjectsFetch {
            return try await pending.value
        }
        let task = Task<[JiraProject], Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.doFetchAndCacheProjects()
        }
        pendingProjectsFetch = task
        do {
            let result = try await task.value
            pendingProjectsFetch = nil
            return result
        } catch {
            pendingProjectsFetch = nil
            throw error
        }
    }

    /// Actual network + cache-store implementation for the projects list.
    /// Only called once per in-flight window via `fetchAndCacheProjects()`.
    private func doFetchAndCacheProjects() async throws -> [JiraProject] {
        // When an allowedProjectKeys allowlist is configured, fetch each project
        // individually in parallel instead of downloading the entire project list.
        // On JIRA Server, GET /rest/api/2/project returns ALL projects with no
        // server-side pagination, so the bulk request can be very large.
        // Cloud's equivalent is smaller by default, but the same optimisation applies.
        let filtered: [JiraProject]
        if let allowed = allowedProjectKeys, !allowed.isEmpty {
            filtered = try await withThrowingTaskGroup(of: JiraProject?.self) { group in
                let client = self.client
                let limiter = self.limiter
                for key in allowed {
                    group.addTask {
                        try? await limiter.run { try await client.getProject(key: key) }
                    }
                }
                var results: [JiraProject] = []
                for try await project in group {
                    if let p = project { results.append(p) }
                }
                return results.sorted { $0.key < $1.key }
            }
        } else {
            let value = try await limiter.run { [client] in
                try await client.listProjects()
            }
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
        // Single-flight deduplication: if warmUp is already fetching this project's
        // issue keys and Finder simultaneously opens the same issues/ directory,
        // join the existing Task rather than starting a second network request.
        if let pending = pendingIssueKeysFetch[key] {
            return try await pending.value
        }
        let task = Task<[String], Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.doFetchAndCacheIssueKeys(forProject: key)
        }
        pendingIssueKeysFetch[key] = task
        do {
            let result = try await task.value
            pendingIssueKeysFetch[key] = nil
            return result
        } catch {
            pendingIssueKeysFetch[key] = nil
            throw error
        }
    }

    private func doFetchAndCacheIssueKeys(forProject key: String) async throws -> [String] {
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

        // Capture actor-isolated state into local constants so that @Sendable
        // task closures can reference them without crossing the actor boundary
        // (required by Swift 6 strict concurrency).
        let client = self.client
        let limiter = self.limiter
        let maxResults = self.maxResults

        let pages = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            var inFlight = 0
            var offsetIterator = offsets.makeIterator()

            while inFlight < concurrencyLimit, let offset = offsetIterator.next() {
                let capturedOffset = offset
                group.addTask {
                    let result = try await limiter.run {
                        try await client.searchIssues(
                            jql: jql,
                            nextPageToken: String(capturedOffset),
                            maxResults: maxResults,
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
                        let result = try await limiter.run {
                            try await client.searchIssues(
                                jql: jql,
                                nextPageToken: String(capturedOffset),
                                maxResults: maxResults,
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
