import Foundation
import Combine
import JiraFSCore
import ConfluenceFSCore

/// Periodically checks which configured JIRA instances are currently mounted
/// and publishes the results so the menu bar and other UI can react.
@MainActor
final class MountStatusMonitor: ObservableObject {

    /// Keyed by instance name → true if mounted.
    @Published private(set) var mountedStates: [String: Bool] = [:]

    /// True if at least one instance is mounted.
    var anyMounted: Bool { mountedStates.values.contains(true) }

    /// Number of currently mounted instances.
    var mountedCount: Int { mountedStates.values.filter { $0 }.count }

    private var pollingTask: Task<Void, Never>?
    private static let pollInterval: TimeInterval = 5

    init() {
        refresh()
        startPolling()
    }

    // MARK: - Internal

    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.refresh() }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() {
        let config = AppConfig.load()
        let confluenceConfig = AppConfig.loadConfluence()
        let mountedURLs = (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardized }

        var updated: [String: Bool] = [:]
        for entry in config.instances {
            let targetURL = URL(fileURLWithPath: entry.effectiveMountPath, isDirectory: true).standardized
            updated[entry.name] = mountedURLs.contains(targetURL)
        }
        for entry in confluenceConfig.instances {
            let targetURL = URL(fileURLWithPath: entry.effectiveMountPath, isDirectory: true).standardized
            updated[entry.name] = mountedURLs.contains(targetURL)
        }
        mountedStates = updated
    }
}
