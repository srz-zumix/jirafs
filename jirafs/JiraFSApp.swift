import SwiftUI

@main
struct JiraFSApp: App {
    var body: some Scene {
        WindowGroup("jirafs", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 480)
        }

        MenuBarExtra("jirafs", image: "MenuBarIcon") {
            MenuBarMenuContent()
        }
    }
}

private struct MenuBarMenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("jirafs を開く") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("終了") {
            NSApplication.shared.terminate(nil)
        }
    }
}
