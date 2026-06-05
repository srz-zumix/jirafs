import Foundation
import Security

// MARK: - Shared error type

enum MountError: LocalizedError {
    case scriptFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return msg
        case .cancelled:             return nil
        }
    }
}

// MARK: - Host validation

/// Returns the URL host only if it is non-empty and consists entirely of
/// characters safe for a single-quoted shell argument (`[A-Za-z0-9._-]`).
/// Returns `nil` for missing, empty, or unsafe values.
func safeHost(from url: URL) -> String? {
    guard let host = url.host, !host.isEmpty else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return host
}

// MARK: - Non-privileged execution

/// Runs `command` via `/bin/sh -c` as the current user (no privilege escalation).
/// Returns `true` if the command exits with code 0, `false` otherwise.
/// Output is suppressed so nothing appears on the console.
func runCommandAsCurrentUser(_ command: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", command]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    } catch {
        return false
    }
}

// MARK: - Privileged execution

/// Executes `command` as root via `AuthorizationExecuteWithPrivileges`.
/// Shows a single interactive Touch ID / password prompt.
/// Throws `MountError`.
func runPrivilegedCommand(_ command: String) throws {
    // 1. Create auth ref.
    var authRef: AuthorizationRef?
    let createStatus = AuthorizationCreate(nil, nil, AuthorizationFlags(), &authRef)
    guard createStatus == errAuthorizationSuccess, let authRef else {
        throw MountError.scriptFailed("Authorization init failed (code \(createStatus))")
    }
    defer { AuthorizationFree(authRef, AuthorizationFlags()) }

    // 2. Request system.privilege.admin with a single interactive prompt.
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
            let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            lines.append(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
        fclose(pipe)
    }

    // 6. Parse exit code from marker.
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
