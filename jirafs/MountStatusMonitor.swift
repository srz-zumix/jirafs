import Foundation
import Combine

/// Periodically checks which configured mounts are currently mounted and
/// publishes the results so the menu bar and other UI can react.
@MainActor
final class MountStatusMonitor: ObservableObject {

    /// Keyed by mount id → true if mounted.
    @Published private(set) var mountedStates: [String: Bool] = [:]

    /// True if at least one mount is mounted.
    var anyMounted: Bool { mountedStates.values.contains(true) }

    /// Number of currently mounted mounts.
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
        let store = AppConfig.loadAppStore()
        let mountedURLs = (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardized }

        var updated: [String: Bool] = [:]
        for mount in store.mounts {
            let targetURL = URL(fileURLWithPath: mount.effectiveMountPath, isDirectory: true).standardized
            updated[mount.id] = mountedURLs.contains(targetURL)
        }
        mountedStates = updated
    }
}
