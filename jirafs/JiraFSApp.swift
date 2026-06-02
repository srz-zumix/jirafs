import SwiftUI
import os

@main
struct JiraFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = MountStatusMonitor()

    var body: some Scene {
        WindowGroup("jirafs", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
                .environmentObject(monitor)
        }

        MenuBarExtra {
            MenuBarMenuContent(monitor: monitor)
        } label: {
            MenuBarLabel()
        }
    }
}

// MARK: - App lifecycle

/// Unmounts all jirafs volumes when the app quits so fskitd is left in a
/// clean state and the next launch can mount without hitting extensionKit error 2.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.zumix.jirafs", category: "AppDelegate")

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
    var body: some View {
        Image("MenuBarIcon")
    }
}

// MARK: - Menu content

private struct MenuBarMenuContent: View {
    @ObservedObject var monitor: MountStatusMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Per-instance status rows
        let config = AppConfig.load()
        let confluenceConfig = AppConfig.loadConfluence()
        let rows: [(name: String, isConfluence: Bool)] =
            config.instances.map { ($0.name, false) }
            + confluenceConfig.instances.map { ($0.name, true) }
        if rows.isEmpty {
            Text("No instances configured")
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows, id: \.name) { row in
                let mounted = monitor.mountedStates[(row.isConfluence ? "confluence" : "jira") + ":\(row.name)"] ?? false
                HStack {
                    Image(systemName: mounted
                          ? "externaldrive.fill.badge.checkmark"
                          : "externaldrive.badge.xmark")
                        .foregroundStyle(mounted ? .green : .secondary)
                        .imageScale(.small)
                    Text(row.name)
                    Spacer()
                    Text(mounted ? "Mounted" : "Not mounted")
                        .foregroundStyle(mounted ? .green : .secondary)
                        .font(.caption)
                }
            }
        }

        Divider()

        Button("Refresh") {
            monitor.refresh()
        }
        .keyboardShortcut("r", modifiers: [])

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
