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

    /// Ensures the one-time mount setup (refresh handler wiring, cache warm-up,
    /// periodic refresh loop) runs exactly once for the volume's lifetime.
    /// fskitd drives the volume through `activate()` rather than `mount()`, and
    /// `activate()` can be called more than once, so the setup is gated on this
    /// flag instead of living in `mount()`.
    let mountSetupOnce = OSAllocatedUnfairLock(initialState: false)

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
        // Wire the refresh handler synchronously at construction — before the
        // volume is handed to FSKit and any enumeration can run — so a background
        // refresh that completes early always bumps the directory mtime and
        // Finder re-enumerates. (Installing it later from async mount setup would
        // leave a window where a refresh could land with no handler, leaving
        // Finder showing a stale listing.)
        dataSource.setListingRefreshedHandler { [weak self] kind in
            guard let self else { return }
            // Bump the directory's mtime so Finder's kqueue watcher sees the
            // change and re-enumerates the listing automatically. Match by `kind`
            // (not fileID): a page directory's fileID encodes its possibly-renamed
            // title, which this pageId-only callback doesn't know, so touchMTime
            // updates every cached item of this kind.
            self.touchMTime(for: kind)
            self.logger.info("listing refreshed kind=\(String(describing: kind), privacy: .public): mtime updated")
        }
    }

    func item(for kind: ConfluenceNodeKind) -> ConfluenceFSItem {
        let id = ConfluenceFSItem.stableID(for: kind)
        itemsLock.lock(); defer { itemsLock.unlock() }
        if let existing = items[id] { return existing }
        let new = ConfluenceFSItem(kind: kind)
        items[id] = new
        return new
    }

    /// Variant of `item(for:)` whose fileID also encodes the directory-entry
    /// display name (and an optional `salt`), so renaming a page yields a new
    /// fileID (Finder treats it as remove + add and refreshes the name) and
    /// editing it — via `salt` = page version on `{Title}.html` — also yields a
    /// new fileID (so Finder regenerates the cached HTML preview). For other
    /// kinds both are ignored, so passing them is harmless.
    func item(for kind: ConfluenceNodeKind, displayName: String?, salt: String? = nil) -> ConfluenceFSItem {
        let id = ConfluenceFSItem.stableID(for: kind, displayName: displayName, salt: salt)
        itemsLock.lock(); defer { itemsLock.unlock() }
        if let existing = items[id] { return existing }
        let new = ConfluenceFSItem(kind: kind, displayName: displayName, salt: salt)
        items[id] = new
        return new
    }

    /// Updates `cachedMTime` on every cached item whose `kind` matches, regardless
    /// of the display-name-derived fileID. A page directory's fileID depends on
    /// its (possibly renamed) title, so a background refresh that only knows the
    /// `pageId` cannot look the item up by ID — it matches on `kind` instead.
    func touchMTime(for kind: ConfluenceNodeKind, to date: Date = Date()) {
        itemsLock.lock(); defer { itemsLock.unlock() }
        for item in items.values where item.kind == kind {
            item.cachedMTime = date
        }
    }

    func release(item: ConfluenceFSItem) {
        itemsLock.lock(); defer { itemsLock.unlock() }
        items.removeValue(forKey: item.identifier.rawValue)
    }
}
