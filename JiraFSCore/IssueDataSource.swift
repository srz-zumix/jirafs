import Foundation
import os
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
    /// Upper bound (bytes) for fully downloading + caching an attachment in
    /// memory. At/under this size an attachment is fetched once and cached so
    /// repeated reads are served locally. Larger (or unknown-size) attachments
    /// are streamed via bounded HTTP Range requests instead, so the extension
    /// never buffers a multi-GB file in memory (OOM/DoS guard).
    public let maxInlineAttachmentBytes: Int
    private let limiter: RateLimiter

    /// Shared attachment byte cache: serves bounded windows of attachment bodies
    /// (streaming large files via Range, caching small files in memory). Cleared
    /// on `synchronize()` and unmount.
    private let attachmentBytes: AttachmentByteCache

    /// Default inline-attachment cap: 16 MiB.
    public static let defaultMaxInlineAttachmentBytes = 16 * 1024 * 1024

    /// Cache keys for which a background refresh is already in flight.
    private var refreshing: Set<String> = []

    /// In-flight background refresh tasks, keyed by cache key. Tracked so they
    /// can be cancelled on unmount; an untracked `Task` would otherwise keep
    /// issuing network requests (and retaining this actor, its HTTP client, and
    /// the cache) after the volume is torn down.
    private var refreshTasks: [String: Task<Void, Never>] = [:]

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

    /// Project keys whose issue-key list has been requested at least once
    /// (i.e. directories the user has actually browsed). The periodic poll only
    /// refreshes these, so projects that were never opened don't generate API
    /// traffic.
    private var browsedProjects: Set<String> = []

    /// Reference-type wrapper for the issue-keys-refreshed handler closure.
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
    private final class IssueKeysRefreshedHandlerBox: Sendable {
        let fire: @Sendable (String) -> Void
        init(_ fire: @escaping @Sendable (String) -> Void) { self.fire = fire }
    }

    /// Called on the actor's executor after every successful background refresh of
    /// the issue key list for a project. The parameter is the project key.
    /// `JiraVolume` uses this to update the directory's `cachedMTime` so that
    /// Finder's kqueue watcher fires and the directory listing auto-refreshes.
    /// Fired regardless of whether the key set actually changed, to ensure Finder
    /// never shows a stale partial listing.
    ///
    /// Stored behind a lock (rather than as actor-isolated state) so the volume
    /// can install it *synchronously* at construction time — before FSKit can
    /// issue the first `enumerateDirectory`/`lookupItem`. Otherwise an early
    /// stale-while-revalidate refresh could complete before an async setter ran,
    /// refreshing the cache without bumping the directory mtime, and Finder would
    /// keep serving a stale listing. Boxed in a class (see
    /// `IssueKeysRefreshedHandlerBox`) so repeated reads don't accumulate
    /// reabstraction thunks.
    private let refreshedHandler = OSAllocatedUnfairLock<IssueKeysRefreshedHandlerBox?>(initialState: nil)

    /// Serial GCD queue used to fire `refreshedHandler` off the Swift cooperative
    /// thread pool. The handler body logs via `os_log` (which needs substantial
    /// stack); running it on a dedicated full-size thread stack — and serializing
    /// invocations when a burst of refresh tasks complete at once — keeps that
    /// logging off the small cooperative-thread stacks.
    private let refreshNotifyQueue = DispatchQueue(label: "com.zumix.jirafs.jira.issuekeys-refresh-notify")

    /// Installs the handler invoked after every successful background refresh of
    /// the issue key list for any project. `nonisolated` + synchronous so it can
    /// run during volume construction, guaranteeing the handler is in place
    /// before any refresh can fire (see `refreshedHandler`).
    public nonisolated func setIssueKeysRefreshedHandler(_ handler: @escaping @Sendable (String) -> Void) {
        refreshedHandler.withLock { $0 = IssueKeysRefreshedHandlerBox(handler) }
    }

    public init(
        client: any JiraClient,
        cache: CacheManager = CacheManager(),
        ttl: Configuration.CacheTTLConfig = .default,
        maxResults: Int = 100,
        allowedProjectKeys: [String]? = nil,
        maxInlineAttachmentBytes: Int = IssueDataSource.defaultMaxInlineAttachmentBytes,
        limiter: RateLimiter = RateLimiter()
    ) {
        self.client = client
        self.cache = cache
        self.ttl = ttl
        self.maxResults = maxResults
        self.maxInlineAttachmentBytes = max(0, maxInlineAttachmentBytes)
        self.attachmentBytes = AttachmentByteCache(maxInlineBytes: max(0, maxInlineAttachmentBytes))
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

    /// Cache key for the filtered projects list. Embeds a fingerprint of the
    /// allowlist so that changing `allowedProjectKeys` (and remounting) never
    /// returns an old cached result from disk.
    private var projectsListKey: String {
        guard let keys = allowedProjectKeys, !keys.isEmpty else { return "projects/*" }
        return "projects/\(keys.sorted().joined(separator: ","))"
    }

    public func projects() async throws -> [JiraProject] {
        let cacheKey = projectsListKey
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
        browsedProjects.insert(key)
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

    /// Returns attachment bytes for the requested window.
    ///
    /// Delegates to the shared ``AttachmentByteCache``, which streams the requested
    /// window via HTTP `Range` and caches small bodies in memory. If the server
    /// ignores `Range` and returns a `200` full body, that body is cached only when
    /// it fits under `maxInlineAttachmentBytes`. A `nil` range returns the whole file.
    public func attachmentData(_ attachment: JiraAttachment, range: Range<Int>? = nil) async throws -> Data {
        try await attachmentBytes.bytes(
            id: attachment.id,
            size: attachment.size >= 0 ? attachment.size : nil,
            range: range,
            rangeFetch: { [client, limiter] range in
                try await limiter.run { try await client.downloadAttachment(attachment, range: range) }
            }
        )
    }

    public func synchronize() async {
        await cache.synchronize()
        await attachmentBytes.clear()
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
    /// immediately after mount. Reads from disk only (stale-OK, no network).
    ///
    /// On a warm disk cache this populates memory in milliseconds.
    /// On a cold disk cache this is a no-op — Finder's first `enumerateDirectory`
    /// call will trigger a lazy network fetch instead.
    ///
    /// Deliberately avoids falling through to network so the FSKit mount reply
    /// is never blocked by API I/O. Network refreshes are handled by
    /// `postWarmUpRefresh()`, which runs after `reply(nil)`.
    public func warmUp() async {
        // Read the project list from the filter-aware key written by
        // `projects()`. Fall back to the legacy unfiltered "projects" key so
        // disk caches written before the key change still warm the cache, and
        // apply the allowlist to avoid iterating projects the mount hides.
        let projects: [JiraProject]
        if let list = await cache.getStale(projectsListKey, as: [JiraProject].self) {
            projects = list
        } else if let legacy = await cache.getStale("projects", as: [JiraProject].self) {
            if let allowed = allowedProjectKeys, !allowed.isEmpty {
                let set = Set(allowed.map { $0.uppercased() })
                projects = legacy.filter { set.contains($0.key.uppercased()) }
            } else {
                projects = legacy
            }
        } else {
            return
        }
        for project in projects {
            _ = await cache.getStale("issues/\(project.key)", as: [String].self)
        }
    }

    /// Schedule background API fetches for all known projects immediately
    /// after `warmUp()`. The cache at this point may be stale disk data or
    /// empty (cold disk); this call ensures the in-memory cache is populated
    /// with fresh network data as soon as possible after mount, without
    /// blocking the reply.
    ///
    /// Skips projects whose issue-key list is already fresh — avoids a
    /// redundant round-trip if the data was already fresh on disk.
    public func postWarmUpRefresh() async {
        guard let projects = try? await self.projects() else { return }
        for project in projects {
            let key = "issues/\(project.key)"
            // cache.get() returns non-nil only for unexpired (fresh) entries.
            // Stale or absent entries proceed to a background refresh.
            if await cache.get(key, as: [String].self) != nil { continue }
            scheduleRefresh(key) { await self.bgRefreshIssueKeys(project: project.key) }
        }
    }

    /// Force a background refresh of the issue-key list for every project the
    /// user has browsed at least once.
    ///
    /// `JiraVolume` calls this on a timer (interval ≈ `ttl.issues`) so that
    /// issues created in JIRA after the directory was last enumerated appear
    /// without the user having to re-trigger enumeration. Each refresh fires
    /// `onIssueKeysRefreshed`, which bumps the directory `mtime` so Finder's
    /// kqueue watcher re-enumerates and surfaces the new entries.
    ///
    /// Refreshes run through `scheduleRefresh`, so a poll that overlaps an
    /// in-flight refresh for the same project is a no-op (no duplicate fetch).
    ///
    /// - Returns: the number of browsed projects a refresh was scheduled for.
    @discardableResult
    public func refreshBrowsedProjects() async -> Int {
        var scheduled = 0
        for project in browsedProjects {
            let cacheKey = "issues/\(project)"
            if scheduleRefresh(cacheKey, task: { await self.bgRefreshIssueKeys(project: project) }) {
                scheduled += 1
            }
        }
        return scheduled
    }

    // MARK: - Background refresh scheduling

    /// Starts a background refresh task for `key` if one is not already running.
    /// - Returns: `true` if a refresh was scheduled, `false` if one was already
    ///   in flight for `key` (so callers can report an accurate scheduled count).
    @discardableResult
    private func scheduleRefresh(_ key: String, task: @escaping @Sendable () async -> Void) -> Bool {
        guard !refreshing.contains(key) else { return false }
        refreshing.insert(key)
        refreshTasks[key] = Task { await task() }
        return true
    }

    private func finishRefresh(_ key: String) {
        refreshing.remove(key)
        refreshTasks[key] = nil
    }

    /// Cancels every in-flight background refresh. Called from `JiraVolume`'s
    /// `unmount` so stale-while-revalidate / periodic refreshes cannot keep
    /// issuing network requests — or retain this actor and its dependencies —
    /// after the volume is gone. URLSession's async API is cancellation-aware,
    /// so cancelling propagates to any request currently on the wire.
    ///
    /// `async` so the attachment temp-file cleanup completes before this returns
    /// (and therefore before `unmount` replies), rather than racing it on an
    /// unstructured `Task`.
    public func cancelBackgroundRefreshes() async {
        for task in refreshTasks.values { task.cancel() }
        refreshTasks.removeAll()
        refreshing.removeAll()
        // Also cancel the unstructured single-flight fetch Tasks. Cancelling a
        // caller awaiting `task.value` does not propagate into these stored
        // Tasks, so without this they keep issuing network requests after unmount.
        pendingProjectsFetch?.cancel()
        pendingProjectsFetch = nil
        for task in pendingIssueKeysFetch.values { task.cancel() }
        pendingIssueKeysFetch.removeAll()
        // Await so any in-flight attachment download is cancelled and its temp
        // files are deleted before unmount reports completion.
        await attachmentBytes.clear()
    }

    // MARK: - Background refresh tasks

    private func bgRefreshProjects() async {
        _ = try? await fetchAndCacheProjects()
        finishRefresh(projectsListKey)
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
        //
        // Fire off the cooperative thread (see `refreshNotifyQueue`). The handler
        // is boxed (see `IssueKeysRefreshedHandlerBox`) so reading it here never
        // accumulates reabstraction thunks on the stored closure.
        if let box = refreshedHandler.withLock({ $0 }) {
            refreshNotifyQueue.async { box.fire(project) }
        }
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
                let cache = self.cache
                let client = self.client
                let limiter = self.limiter
                let projectTTL = ttl.projects
                for key in allowed {
                    group.addTask {
                        // Reuse the individual project cache (fresh or stale) so
                        // that narrowing the filter (e.g. AAA/BBB/CCC → BBB/CCC)
                        // assembles the result from cache without any API call.
                        let indivKey = "project/\(key)"
                        if let fresh = await cache.get(indivKey, as: JiraProject.self) {
                            return fresh
                        }
                        if let stale = await cache.getStale(indivKey, as: JiraProject.self) {
                            return stale
                        }
                        // Populate the per-project cache on fetch so a later
                        // allowlist change can assemble the list from cache.
                        if let project = try? await limiter.run({ try await client.getProject(key: key) }) {
                            await cache.set(indivKey, value: project, ttl: projectTTL)
                            return project
                        }
                        return nil
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
        await cache.set(projectsListKey, value: filtered, ttl: ttl.projects)
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
