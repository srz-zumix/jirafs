import SwiftUI
import os

@main
struct JiraFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = MountStatusMonitor()
    @StateObject private var navigation = NavigationModel()
    @StateObject private var launchAtLogin = LaunchAtLoginManager()

    var body: some Scene {
        Window("jirafs", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
                .environmentObject(monitor)
                .environmentObject(navigation)
        }
        .defaultSize(width: 800, height: 600)

        MenuBarExtra {
            MenuBarMenuContent(monitor: monitor, navigation: navigation, launchAtLogin: launchAtLogin)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
    }
}

// MARK: - Navigation state

/// Shared navigation intent passed from the menu bar to ContentView.
@MainActor
final class NavigationModel: ObservableObject {
    /// Instance ID ("jira:NAME" / "confluence:NAME") to select on next window open.
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
        let config = AppConfig.load()
        let confluenceConfig = AppConfig.loadConfluence()
        let fm = FileManager.default
        let mountedURLs = (fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardized }

        struct MountTarget { let name: String; let path: String; let cmd: String }
        var targets: [MountTarget] = []

        for entry in config.instances where entry.autoMount {
            guard let host = safeHost(from: entry.url) else {
                logger.warning("Auto-mount skipped for '\(entry.name, privacy: .public)': invalid URL host")
                continue
            }
            let path = entry.effectiveMountPath
            let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardized
            guard !mountedURLs.contains(targetURL) else { continue }
            let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
            targets.append(MountTarget(
                name: entry.name,
                path: path,
                cmd: "/sbin/mount -F -t jirafs -o ro 'jira://\(host)' '\(escapedPath)'"
            ))
        }

        for entry in confluenceConfig.instances where entry.autoMount {
            guard let host = safeHost(from: entry.url) else {
                logger.warning("Auto-mount skipped for '\(entry.name, privacy: .public)': invalid URL host")
                continue
            }
            let path = entry.effectiveMountPath
            let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardized
            guard !mountedURLs.contains(targetURL) else { continue }
            let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
            targets.append(MountTarget(
                name: entry.name,
                path: path,
                cmd: "/sbin/mount -F -t confluencefs -o ro 'confluence://\(host)' '\(escapedPath)'"
            ))
        }

        guard !targets.isEmpty else { return }

        for target in targets {
            try? fm.createDirectory(atPath: target.path, withIntermediateDirectories: true)
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

    func applicationWillTerminate(_ notification: Notification) {
        let config = AppConfig.load()
        let confluenceConfig = AppConfig.loadConfluence()
        let fm = FileManager.default
        let mountedURLs = (fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardized }

        let mountPoints: [(name: String, path: String)] =
            config.instances.map { ($0.name, $0.effectiveMountPath) }
            + confluenceConfig.instances.map { ($0.name, $0.effectiveMountPath) }

        for instance in mountPoints {
            let targetURL = URL(fileURLWithPath: instance.path,
                                isDirectory: true).standardized
            guard mountedURLs.contains(targetURL) else { continue }
            // Try non-privileged NSWorkspace unmount first.
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: targetURL)
                logger.info("Unmounted \(instance.name, privacy: .public) via NSWorkspace")
            } catch {
                // Fallback: synchronous diskutil without sudo.
                // FSKit volumes are user-owned (fskitd runs as the user), so this
                // should succeed without requiring root privileges.
                logger.warning("NSWorkspace unmount failed for \(instance.name, privacy: .public): \(error.localizedDescription, privacy: .public) — retrying via diskutil")
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                proc.arguments = ["unmount", "force", instance.path]
                try? proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    logger.info("Unmounted \(instance.name, privacy: .public) via diskutil")
                } else {
                    logger.error("diskutil unmount failed for \(instance.name, privacy: .public) (exit \(proc.terminationStatus))")
                }
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
        // マウント済みインスタンスのみ表示
        let config = AppConfig.load()
        let confluenceConfig = AppConfig.loadConfluence()
        let allRows: [(id: String, name: String)] =
            config.instances.map { ("jira:\($0.name)", $0.name) }
            + confluenceConfig.instances.map { ("confluence:\($0.name)", $0.name) }
        let mountedRows = allRows.filter { monitor.mountedStates[$0.id] == true }

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
