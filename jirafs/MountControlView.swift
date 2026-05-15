import SwiftUI
import AppKit
import Security
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
        } catch MountError.cancelled {
            // ユーザーが Touch ID / パスワードダイアログをキャンセルした場合はエラー非表示。
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
        } catch MountError.cancelled {
            // キャンセル時はエラー非表示。
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

    /// Runs `command` with root privileges.
    /// Shows exactly ONE prompt via Authorization Services, which automatically
    /// offers Touch ID when "System Settings › Touch ID & Password ›
    /// Use Touch ID for administrator actions" is enabled, with password fallback.
    private func runPrivileged(_ command: String) async throws {
        // Authorization Services blocks the calling thread; run off main.
        try await Task.detached(priority: .userInitiated) {
            try MountControlView.executeWithAuthorization(command)
        }.value
    }

    /// Executes `command` as root via `AuthorizationExecuteWithPrivileges`.
    /// Marked `nonisolated` so it can be called from a detached task.
    nonisolated private static func executeWithAuthorization(_ command: String) throws {
        // 1. Create auth ref
        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, AuthorizationFlags(), &authRef)
        guard createStatus == errAuthorizationSuccess, let authRef else {
            throw MountError.scriptFailed("Authorization init failed (code \(createStatus))")
        }
        defer { AuthorizationFree(authRef, AuthorizationFlags()) }

        // 2. Request system.privilege.admin with a single interactive prompt.
        //    Authorization Services shows Touch ID (if "Use Touch ID for
        //    administrator actions" is enabled in System Settings) or password.
        var copyStatus: OSStatus = errAuthorizationInternal
        kAuthorizationRightExecute.withCString { namePtr in
            var item = AuthorizationItem(name: namePtr, valueLength: 0, value: nil, flags: 0)
            withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                copyStatus = AuthorizationCopyRights(
                    authRef, &rights, nil,
                    [.interactionAllowed, .preAuthorize, .extendRights], nil)
            }
        }
        switch copyStatus {
        case errAuthorizationSuccess:  break
        case errAuthorizationCanceled: throw MountError.cancelled
        default: throw MountError.scriptFailed("Authorization denied (code \(copyStatus))")
        }

        // 3. AuthorizationExecuteWithPrivileges is deprecated since macOS 10.7 and
        //    marked unavailable in Swift. Call it via dlsym to bypass that check;
        //    the symbol remains present in Security.framework on macOS 15.
        //    (A privileged helper via SMAppService would be the long-term solution.)
        typealias AuthExecFn = @convention(c) (
            OpaquePointer,
            UnsafePointer<CChar>,
            UInt32,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
            UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
        ) -> OSStatus
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "AuthorizationExecuteWithPrivileges") else {
            throw MountError.scriptFailed("AuthorizationExecuteWithPrivileges not found in Security.framework")
        }
        let authExec = unsafeBitCast(sym, to: AuthExecFn.self)

        // 4. Build argv: redirect stderr → stdout and emit exit-code marker.
        let wrapped = "\(command) 2>&1; printf '__EXIT__:%d\\n' $?"
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(wrapped), nil]
        defer { argv.dropLast().forEach { free($0) } }

        var commPipe: UnsafeMutablePointer<FILE>?
        typealias CStrOptPtr = UnsafeMutablePointer<CChar>?
        let execStatus = argv.withUnsafeMutableBytes { rawBuf in
            authExec(
                authRef,
                "/bin/sh",
                0,
                rawBuf.baseAddress?.assumingMemoryBound(to: CStrOptPtr.self),
                &commPipe)
        }
        guard execStatus == errAuthorizationSuccess else {
            throw MountError.scriptFailed("Failed to start privileged process (code \(execStatus))")
        }

        // 5. Drain stdout (stderr is merged).
        var lines: [String] = []
        if let pipe = commPipe {
            var buf = [CChar](repeating: 0, count: 512)
            while fgets(&buf, 512, pipe) != nil {
                lines.append(String(cString: buf).trimmingCharacters(in: .newlines))
            }
            fclose(pipe)
        }

        // 6. Parse exit code from marker; remaining lines are potential error output.
        var exitCode = 0
        var outputLines: [String] = []
        for line in lines {
            if line.hasPrefix("__EXIT__:"), let code = Int(line.dropFirst("__EXIT__:".count)) {
                exitCode = code
            } else {
                outputLines.append(line)
            }
        }
        if exitCode != 0 {
            let msg = outputLines.filter { !$0.isEmpty }.joined(separator: "\n")
            throw MountError.scriptFailed(msg.isEmpty ? "Command failed (exit \(exitCode))" : msg)
        }
    }
}

private enum MountError: LocalizedError {
    case scriptFailed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return msg
        case .cancelled: return nil
        }
    }
}
