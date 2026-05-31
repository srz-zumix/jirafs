import Foundation
import FSKit
import AtlassianCore
import ConfluenceAPI
import ConfluenceFSCore
import os

/// `FSVolume` subclass that fronts a single Confluence instance as a filesystem.
/// Phase 1 is read-only. All write entry points return `EROFS`/`ENOTSUP`.
@available(macOS 15.4, *)
final class ConfluenceVolume: FSVolume, @unchecked Sendable {
    let dataSource: PageDataSource
    let instanceName: String
    let isReadOnly: Bool
    let htmlEnabled: Bool
    let logger = AtlassianLog.logger("confluence-volume")

    let itemsLock = NSLock()
    var items: [UInt64: ConfluenceFSItem] = [:]

    // MARK: - Task lifecycle tracking

    private struct TaskState {
        var tasks: [UInt64: Task<Void, Never>] = [:]
        var nextID: UInt64 = 0
    }
    private let taskStorage = OSAllocatedUnfairLock(initialState: TaskState())

    @discardableResult
    func makeTask(_ body: @Sendable @escaping () async -> Void) -> Task<Void, Never> {
        let id = taskStorage.withLock { state -> UInt64 in
            let id = state.nextID
            state.nextID &+= 1
            return id
        }
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

    func cancelAllTasks() {
        let snapshot = taskStorage.withLock { state -> [UInt64: Task<Void, Never>] in
            let s = state.tasks
            state.tasks = [:]
            return s
        }
        snapshot.values.forEach { $0.cancel() }
    }

    init(name: String, dataSource: PageDataSource, isReadOnly: Bool, htmlEnabled: Bool = false) {
        self.dataSource = dataSource
        self.instanceName = name
        self.isReadOnly = isReadOnly
        self.htmlEnabled = htmlEnabled
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()),
                   volumeName: FSFileName(string: "confluencefs-\(name)"))
    }

    func item(for kind: ConfluenceNodeKind) -> ConfluenceFSItem {
        let id = ConfluenceFSItem.stableID(for: kind)
        itemsLock.lock(); defer { itemsLock.unlock() }
        if let existing = items[id] { return existing }
        let new = ConfluenceFSItem(kind: kind)
        items[id] = new
        return new
    }

    func release(item: ConfluenceFSItem) {
        itemsLock.lock(); defer { itemsLock.unlock() }
        items.removeValue(forKey: item.identifier.rawValue)
    }
}
