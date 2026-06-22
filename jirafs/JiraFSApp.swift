import SwiftUI
import os

@main
struct JiraFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = MountStatusMonitor()
    @StateObject private var navigation = NavigationModel()
    @StateObject private var launchAtLogin = LaunchAtLoginManager()
    @StateObject private var appStore = AppStoreModel()

    var body: some Scene {
        Window("jirafs", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
                .environmentObject(monitor)
                .environmentObject(navigation)
                .environmentObject(appStore)
        }
        .defaultSize(width: 800, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About jirafs") {
                    AboutPanel.show()
                }
            }
        }

        MenuBarExtra {
            MenuBarMenuContent(monitor: monitor, navigation: navigation, launchAtLogin: launchAtLogin)
        } label: {
            MenuBarLabel(monitor: monitor)
        }

        Settings {
            PreferencesView()
                .environmentObject(monitor)
                .environmentObject(launchAtLogin)
                .environmentObject(appStore)
        }
    }
}

// MARK: - Navigation state

/// Shared navigation intent passed from the menu bar to ContentView.
@MainActor
final class NavigationModel: ObservableObject {
    /// Mount id to select on next window open.
    @Published var pendingSelection: String?
}

// MARK: - App lifecycle

/// Unmounts all jirafs volumes when the app quits so fskitd is left in a
/// clean state and the next launch can mount without hitting extensionKit error 2.
/// Single-instance enforcement is handled via LSMultipleInstancesProhibited in Info.plist.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.zumix.jirafs", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await performAutoMount() }
    }

    // MARK: - Auto-mount

    private func performAutoMount() async {
        let store = AppConfig.loadAppStore()
        let fm = FileManager.default
        let mountedURLs = (fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardized }

        struct MountTarget { let name: String; let path: String; let cmd: String }
        var targets: [MountTarget] = []

        for mount in store.mounts where mount.autoMount {
            // Only auto-mount mounts whose server still provides the product.
            guard let server = store.server(id: mount.serverID),
                  server.supports(mount.product) else {
                logger.warning("Auto-mount skipped for '\(mount.name, privacy: .public)': server missing or product unavailable")
                continue
            }
            let host = mount.id  // mount id is the URL host
            // Validate: mount.id must consist only of characters safe for a
            // single-quoted shell argument before it is interpolated into the
            // mount command. appstore.json is user-writable, so a tampered id
            // containing shell metacharacters could otherwise lead to arbitrary
            // command execution. UUIDs pass this check; anything else is rejected.
            guard let mountURL = URL(string: "\(mount.product.scheme)://\(host)"),
                  let safeID = safeHost(from: mountURL) else {
                logger.warning("Auto-mount skipped for '\(mount.name, privacy: .public)': mount id contains unsafe characters")
                continue
            }
            let path = mount.effectiveMountPath
            let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardized
            guard !mountedURLs.contains(targetURL) else { continue }
            let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
            targets.append(MountTarget(
                name: mount.name,
                path: path,
                cmd: "/sbin/mount -F -t \(mount.product.fsType) -o ro '\(mount.product.scheme)://\(safeID)' '\(escapedPath)'"
            ))
        }

        guard !targets.isEmpty else { return }

        for target in targets {
            do {
                try fm.createDirectory(atPath: target.path, withIntermediateDirectories: true)
            } catch {
                logger.error("Auto-mount skipped for '\(target.name, privacy: .public)': cannot create mount directory '\(target.path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                continue
            }
            let cmd = target.cmd
            let name = target.name
            // FSKit volumes are managed by fskitd (a user-space daemon). Attempt
            // mount as the current user first so no authentication dialog appears
            // at startup. If the OS requires root for this volume type, the mount
            // silently fails here and the user can mount manually from the UI.
            let succeeded = await Task.detached(priority: .userInitiated) {
                runCommandAsCurrentUser(cmd)
            }.value
            if succeeded {
                logger.info("Auto-mounted '\(name, privacy: .public)' (non-privileged)")
            } else {
                logger.warning("Auto-mount skipped for '\(name, privacy: .public)': non-privileged mount failed. Use the Mount button in the app to mount with authentication.")
            }
        }
    }

    /// Upper bound on how long quit will wait for *all* volumes to unmount
    /// before terminating anyway. `NSWorkspace.unmountAndEjectDevice` (and the
    /// `diskutil` fallback) are synchronous with no timeout, so a volume that is
    /// slow to eject — e.g. its extension's cache actor is saturated flushing
    /// the encrypted disk cache — would otherwise block the main thread forever
    /// and the app could never quit (observed as a 384 s hang in
    /// `applicationWillTerminate`). Any volume not unmounted within this budget
    /// is left for fskitd / the next launch to reconcile.
    private static let unmountOnQuitTimeout: DispatchTimeInterval = .seconds(8)

    func applicationWillTerminate(_ notification: Notification) {
        let store = AppConfig.loadAppStore()
        let fm = FileManager.default
        let mountedURLs = (fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardized }

        let mountPoints: [(name: String, path: String)] =
            store.mounts
                .map { ($0.name, $0.effectiveMountPath) }
                .filter { mountedURLs.contains(URL(fileURLWithPath: $0.1, isDirectory: true).standardized) }

        guard !mountPoints.isEmpty else { return }

        // Unmount every volume off the main thread, concurrently, and wait only a
        // bounded amount of time. The eject calls block with no timeout of their
        // own, so doing them inline on the main thread freezes termination when a
        // volume is busy. Dispatching them and waiting with a deadline lets the
        // common (idle volume) case still unmount cleanly while guaranteeing the
        // app can always terminate. Threads still blocked at the deadline are
        // torn down when the process exits.
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.zumix.jirafs.terminate-unmount",
                                  attributes: .concurrent)
        for instance in mountPoints {
            group.enter()
            // Capture self strongly: the app delegate lives for the whole app
            // lifetime (owned by NSApplication) and applicationWillTerminate is
            // blocked on group.wait below, so there is no retain-cycle risk. A
            // weak capture could only turn this into a silent no-op that skips
            // the unmount it is meant to perform.
            queue.async {
                defer { group.leave() }
                self.unmountVolumeOnQuit(name: instance.name, path: instance.path)
            }
        }
        if group.wait(timeout: .now() + AppDelegate.unmountOnQuitTimeout) == .timedOut {
            logger.warning("Unmount on quit timed out after \(String(describing: AppDelegate.unmountOnQuitTimeout), privacy: .public); terminating without confirming all unmounts")
        }
    }

    /// Unmounts a single volume, trying the non-privileged `NSWorkspace` path
    /// first and falling back to `diskutil unmount force`. Both calls are
    /// synchronous; callers must run this off the main thread under a bounded
    /// wait (see `applicationWillTerminate`).
    private func unmountVolumeOnQuit(name: String, path: String) {
        let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardized
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: targetURL)
            logger.info("Unmounted \(name, privacy: .public) via NSWorkspace")
        } catch {
            // Fallback: synchronous diskutil without sudo.
            // FSKit volumes are user-owned (fskitd runs as the user), so this
            // should succeed without requiring root privileges.
            logger.warning("NSWorkspace unmount failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public) — retrying via diskutil")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            proc.arguments = ["unmount", "force", path]
            try? proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                logger.info("Unmounted \(name, privacy: .public) via diskutil")
            } else {
                logger.error("diskutil unmount failed for \(name, privacy: .public) (exit \(proc.terminationStatus))")
            }
        }
    }
}

// MARK: - Menu bar icon + label

private struct MenuBarLabel: View {
    @ObservedObject var monitor: MountStatusMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarIcon")
                .renderingMode(.template)
            if monitor.mountedCount > 0 {
                Text("\(monitor.mountedCount)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
        }
    }
}

// MARK: - Menu content

private struct MenuBarMenuContent: View {
    @ObservedObject var monitor: MountStatusMonitor
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // マウント済みのマウントのみ表示
        let store = AppConfig.loadAppStore()
        let mountedRows = store.mounts
            .filter { monitor.mountedStates[$0.id] == true }
            .map { (id: $0.id, name: $0.name) }

        if mountedRows.isEmpty {
            Text("No instances mounted")
                .foregroundStyle(.secondary)
        } else {
            ForEach(mountedRows, id: \.id) { row in
                Button {
                    navigation.pendingSelection = row.id
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label(row.name, systemImage: "externaldrive.fill.badge.checkmark")
                }
            }
        }

        Divider()

        Button("Refresh") {
            monitor.refresh()
        }
        .keyboardShortcut("r", modifiers: [])

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        ))

        Divider()

        Button("Open jirafs…") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o", modifiers: [])

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [])
    }
}
