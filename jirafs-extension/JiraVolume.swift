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
    let logger = JiraLog.logger("volume")

    /// Cache of currently-known items (keyed by identifier raw value) so we
    /// can hand the same instance back to FSKit consistently.
    private let itemsLock = NSLock()
    private var items: [UInt64: JiraFSItem] = [:]

    init(name: String, dataSource: IssueDataSource, isReadOnly: Bool) {
        self.dataSource = dataSource
        self.instanceName = name
        self.isReadOnly = isReadOnly
        let uuid = JiraFileSystem.deterministicUUID(for: name)
        super.init(volumeID: FSVolume.Identifier(uuid: uuid),
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
