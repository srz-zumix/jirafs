import SwiftUI
import os

@main
struct JiraFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = MountStatusMonitor()
    @StateObject private var navigation = NavigationModel()

    var body: some Scene {
        Window("jirafs", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
                .environmentObject(monitor)
                .environmentObject(navigation)
        }
        .defaultSize(width: 800, height: 600)

        MenuBarExtra {
            MenuBarMenuContent(monitor: monitor, navigation: navigation)
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
