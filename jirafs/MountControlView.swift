import SwiftUI
import AppKit
import JiraAPI
import JiraFSCore

/// Displays mount status and provides Mount / Unmount buttons.
///
/// **Mount** creates the directory via FileManager then runs:
///   `/sbin/mount -F -t jirafs -o ro jira://<host> <path>`
/// via `Security.AuthorizationExecuteWithPrivileges` (shows the standard
/// macOS password dialog via SecurityAgent).
///
/// **Unmount** first tries `NSWorkspace.unmountAndEjectDevice(at:)` (no
/// privileges needed when the current user owns the mount), and falls back to
/// `/usr/sbin/diskutil unmount force` via the same privileged API.
@MainActor
struct MountControlView: View {
    let entry: Configuration.InstanceEntry
    @State private var isMounted = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Status row
                HStack(spacing: 8) {
                    Image(systemName: isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark")
                        .foregroundStyle(isMounted ? .green : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isMounted ? "Mounted" : "Not mounted")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(isMounted ? .primary : .secondary)
                        Text(entry.effectiveMountPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if isBusy { ProgressView().scaleEffect(0.7) }
                }

                if let errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        // Error message – selectable text
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .font(.caption)
                                .padding(.top, 1)
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.caption)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(errorMessage, forType: .string)
                            } label: { Image(systemName: "doc.on.doc").font(.caption2) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Copy error message")
                        }
                        // Manual fallback command
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Manual command:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Text(manualMountCommand)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                                Spacer(minLength: 0)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(manualMountCommand, forType: .string)
                                } label: { Image(systemName: "doc.on.doc").font(.caption2) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Copy command")
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Action buttons
                HStack(spacing: 6) {
                    Button {
                        Task { await performMount() }
                    } label: {
                        Label("Mount", systemImage: "externaldrive.badge.plus")
                            .frame(minWidth: 70)
                    }
                    .disabled(isMounted || isBusy)

                    Button {
                        Task { await performUnmount() }
                    } label: {
                        Label("Unmount", systemImage: "externaldrive.badge.minus")
                            .frame(minWidth: 70)
                    }
                    .disabled(!isMounted || isBusy)

                    Spacer()

                    Button {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: entry.effectiveMountPath, isDirectory: true))
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .disabled(!isMounted)
                }
                .buttonStyle(.bordered)

                // System Settings shortcut
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Extension Settings", systemImage: "gear")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } label: {
            Label("Mount", systemImage: "externaldrive")
                .font(.callout.weight(.semibold))
        }
        .task { await refreshMountStatus() }
    }

    // MARK: - Actions

    // The command shown to users as a fallback when mount fails.
    private var manualMountCommand: String {
        let host = entry.url.host ?? entry.url.absoluteString
        let path = entry.effectiveMountPath.replacingOccurrences(of: "'", with: "'\\''")
        return "sudo /sbin/mount -F -t jirafs -o ro jira://\(host) '\(path)'"
    }

    private func performMount() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let path = entry.effectiveMountPath
        let host = entry.url.host ?? entry.url.absoluteString
        // Create the mount point as the current user (no root needed).
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Cannot create directory: \(error.localizedDescription)"
            return
        }
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let mountCmd = "/sbin/mount -F -t jirafs -o ro jira://\(host) '\(escapedPath)'"
        do {
            try await runPrivileged(mountCmd)
            await refreshMountStatus()
            if !isMounted {
                errorMessage = "Mount command completed but volume is not visible. Check fskitd and pluginkit registration."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performUnmount() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let url = URL(fileURLWithPath: entry.effectiveMountPath, isDirectory: true)
        // Try the non-privileged route first (works when current user owns the mount).
        if (try? NSWorkspace.shared.unmountAndEjectDevice(at: url)) != nil {
            await refreshMountStatus()
            return
        }
        // Fallback: privileged diskutil.
        let escapedPath = entry.effectiveMountPath.replacingOccurrences(of: "'", with: "'\\''")
        do {
            try await runPrivileged("/usr/sbin/diskutil unmount force '\(escapedPath)'")
            await refreshMountStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func refreshMountStatus() async {
        let target = entry.effectiveMountPath
        let targetURL = URL(fileURLWithPath: target, isDirectory: true)
            .standardized
        let fm = FileManager.default
        let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        isMounted = mounted.contains { $0.standardized == targetURL }
    }

    /// Runs `command` with root privileges via `do shell script … with administrator privileges`.
    /// Works in non-sandboxed apps; shows the standard macOS password dialog.
    private func runPrivileged(_ command: String) async throws {
        // NSAppleScript must run on the main thread.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        let script = NSAppleScript(source: source)!
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let msg = (info[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            let code = info[NSAppleScript.errorNumber] as? Int
            let detail = code.map { "\(msg) (code \($0))" } ?? msg
            throw MountError.scriptFailed(detail)
        }
    }
}

private enum MountError: LocalizedError {
    case scriptFailed(String)
    var errorDescription: String? {
        if case .scriptFailed(let msg) = self { return msg }
        return nil
    }
}
