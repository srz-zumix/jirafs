import SwiftUI

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
    func applicationWillTerminate(_ notification: Notification) {
        let config = AppConfig.load()
        let fm = FileManager.default
        let mountedURLs = (fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.standardized }

        for entry in config.instances {
            let targetURL = URL(fileURLWithPath: entry.effectiveMountPath,
                                isDirectory: true).standardized
            guard mountedURLs.contains(targetURL) else { continue }
            // Best-effort synchronous unmount; no auth dialog at quit time.
            _ = NSWorkspace.shared.unmountAndEjectDevice(atPath: entry.effectiveMountPath)
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
        if config.instances.isEmpty {
            Text("No instances configured")
                .foregroundStyle(.secondary)
        } else {
            ForEach(config.instances) { entry in
                let mounted = monitor.mountedStates[entry.name] ?? false
                HStack {
                    Image(systemName: mounted
                          ? "externaldrive.fill.badge.checkmark"
                          : "externaldrive.badge.xmark")
                        .foregroundStyle(mounted ? .green : .secondary)
                        .imageScale(.small)
                    Text(entry.name)
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
