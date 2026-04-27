import SwiftUI
import JiraAPI
import JiraFSCore

/// Provides the user with mount instructions and a button that opens the
/// system-extensions settings pane.
///
/// Programmatic mounting via `FSFileSystemKit.FSMountManager` is documented
/// for reference in `docs/INSTRUCTIONS.md` but is not invoked here directly to
/// keep Phase 1 self-contained.
struct MountControlView: View {
    let entry: Configuration.InstanceEntry
    @State private var readOnly: Bool = true

    var body: some View {
        GroupBox("Mount") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Read-only", isOn: $readOnly)
                Text("Mount command:").font(.headline)
                Text(mountCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                Text("Run the command in Terminal after enabling the FSKit extension in System Settings → Login Items & Extensions → File System Extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Extension Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var mountCommand: String {
        let opt = readOnly ? "-o ro" : "-o rw"
        let host = entry.url.host ?? "example.atlassian.net"
        return "mkdir -p ~/jirafs && mount -F -t jirafs \(opt) jira://\(host) ~/jirafs"
    }
}
