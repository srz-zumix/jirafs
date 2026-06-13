import Foundation
import FSKit
import JiraAPI
import JiraFSCore
import os

/// `FSVolume` subclass that fronts a single JIRA instance as a filesystem.
///
/// Phase 1 is read-only. All write entry points return `ENOTSUP`.
@available(macOS 15.4, *)
final class JiraVolume: FSVolume, @unchecked Sendable {
    let dataSource: IssueDataSource
    let instanceName: String
    let isReadOnly: Bool
    let htmlEnabled: Bool
    let logger = JiraLog.logger("volume")

    /// Cache of currently-known items (keyed by identifier raw value) so we
    /// can hand the same instance back to FSKit consistently.
    let itemsLock = NSLock()
    private var items: [UInt64: JiraFSItem] = [:]

    /// Cached directory entry arrays for each project's issuesDir, keyed by
    /// project key. Avoids rebuilding the O(N) tuple array on every
    /// enumerateDirectory pagination call (30,000+ issues require ~70 calls).
    /// Invalidated by onIssueKeysRefreshed after each successful refresh.
    /// Protected by itemsLock.
    var issueEntriesCache: [String: [(String, FSNodeKind)]] = [:]

    /// Monotonically increasing invalidation counter per project.
    /// Incremented by onIssueKeysRefreshed alongside the cache clear.
    /// children(of:) captures the generation before the async issueKeys() call
    /// and refuses to store a rebuilt entry array if the counter has advanced,
    /// preventing a stale key snapshot from overwriting a newer valid cache.
    /// Protected by itemsLock.
    var issueEntriesGeneration: [String: Int] = [:]

    /// Per-project Set of issue keys for O(1) existence checks in resolveChild.
    /// Built and invalidated together with issueEntriesCache.
    /// Protected by itemsLock.
    var issueKeysSet: [String: Set<String>] = [:]

    // MARK: - Task lifecycle tracking

    /// Storage for in-flight task handles, protected by an async-safe lock.
    /// `OSAllocatedUnfairLock.withLock` is safe to call from async contexts
    /// (unlike `NSLock.lock()`/`unlock()` which are `@available(*, noasync)`).
    private struct TaskState {
        var tasks: [UInt64: Task<Void, Never>] = [:]
        var nextID: UInt64 = 0
    }
    private let taskStorage = OSAllocatedUnfairLock(initialState: TaskState())

    /// Ensures the one-time mount setup (refresh handler wiring, cache warm-up,
    /// post-warm-up refresh, periodic refresh loop) runs exactly once for the
    /// volume's lifetime. fskitd drives the volume through `activate()` rather
    /// than `mount()`, and `activate()` can be called more than once, so the
    /// setup is gated on this flag instead of living in `mount()`.
    let mountSetupOnce = OSAllocatedUnfairLock(initialState: false)

    /// Creates a `Task<Void, Never>` whose lifetime is tracked by this volume.
    /// The task removes itself from tracking when it finishes.
    /// Call `cancelAllTasks()` in `unmount` to abort in-flight work before
    /// FSKit tears down the volume.
    @discardableResult
    func makeTask(_ body: @Sendable @escaping () async -> Void) -> Task<Void, Never> {
        let id = taskStorage.withLock { state -> UInt64 in
            let id = state.nextID
            state.nextID &+= 1
            return id
        }
        // Gate: the task body suspends here until taskStorage.tasks[id] has been
        // set by the caller below. Without this, a fast-completing body's `defer`
        // could remove a not-yet-inserted entry; the subsequent insertion would
        // then leave a stale completed task permanently in the dictionary.
        // Two orderings are handled:
        //   (A) task starts first  → stores the continuation; signal() resumes it.
        //   (B) signal() runs first → sets `go = true`; task resumes immediately.
        let gate = OSAllocatedUnfairLock(
            initialState: (cont: Optional<CheckedContinuation<Void, Never>>.none, go: false))
        let task = Task<Void, Never> {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gate.withLock { s in
                    if s.go { c.resume() } else { s.cont = c }
                }
            }
            defer { _ = self.taskStorage.withLock { $0.tasks.removeValue(forKey: id) } }
            await body()
        }
        taskStorage.withLock { $0.tasks[id] = task }
        gate.withLock { s in
            s.go = true
            s.cont?.resume()
        }
        return task
    }

    /// Cancels every tracked in-flight task. Call before `unmount reply()`.
    func cancelAllTasks() {
        let snapshot = taskStorage.withLock { state -> [UInt64: Task<Void, Never>] in
            let s = state.tasks
            state.tasks = [:]
            return s
        }
        snapshot.values.forEach { $0.cancel() }
    }

    init(name: String, dataSource: IssueDataSource, isReadOnly: Bool, htmlEnabled: Bool = false) {
        self.dataSource = dataSource
        self.instanceName = name
        self.isReadOnly = isReadOnly
        self.htmlEnabled = htmlEnabled
        // Use random UUID per mount to avoid fskitd container cache collisions.
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()),
                   volumeName: FSFileName(string: "jirafs-\(name)"))
        // Wire the refresh handler synchronously at construction — before the
        // volume is handed to FSKit and any enumeration can run — so a
        // stale-while-revalidate refresh that completes early always bumps the
        // directory mtime and invalidates the entries cache. (Installing it
        // later from async mount setup would leave a window where a refresh
        // could land with no handler, leaving Finder showing a stale listing.)
        dataSource.setIssueKeysRefreshedHandler { [weak self] projectKey in
            guard let self else { return }
            // Update the issuesDir mtime so Finder's kqueue watcher sees the
            // change and re-enumerates the directory automatically. Called after
            // every successful background refresh (not only on key-set change)
            // to prevent stale partial listings in Finder.
            let node = self.item(for: .issuesDir(project: projectKey))
            node.cachedMTime = Date()
            // Invalidate the enumeration entries cache and bump the generation so
            // any in-flight children() call that captured the old generation will
            // not overwrite the cleared cache.
            self.itemsLock.withLock {
                self.issueEntriesCache[projectKey] = nil
                self.issueKeysSet[projectKey] = nil
                self.issueEntriesGeneration[projectKey, default: 0] += 1
            }
            self.logger.info("issueKeys refreshed project=\(projectKey, privacy: .public): mtime updated, entries cache invalidated")
        }
    }

    func item(for kind: FSNodeKind) -> JiraFSItem {
        let id = JiraFSItem.stableID(for: kind)
        itemsLock.lock(); defer { itemsLock.unlock() }
        if let existing = items[id] { return existing }
        let new = JiraFSItem(kind: kind)
        items[id] = new
        return new
    }

    func release(item: JiraFSItem) {
        itemsLock.lock(); defer { itemsLock.unlock() }
        items.removeValue(forKey: item.identifier.rawValue)
    }
}
