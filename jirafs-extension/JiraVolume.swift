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
    private let itemsLock = NSLock()
    private var items: [UInt64: JiraFSItem] = [:]

    // MARK: - Task lifecycle tracking

    /// Storage for in-flight task handles, protected by an async-safe lock.
    /// `OSAllocatedUnfairLock.withLock` is safe to call from async contexts
    /// (unlike `NSLock.lock()`/`unlock()` which are `@available(*, noasync)`).
    private struct TaskState {
        var tasks: [UInt64: Task<Void, Never>] = [:]
        var nextID: UInt64 = 0
    }
    private let taskStorage = OSAllocatedUnfairLock(initialState: TaskState())

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
