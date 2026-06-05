import Foundation
import ServiceManagement
import os

/// Manages the "Launch at Login" registration for jirafs via SMAppService.
///
/// Uses `SMAppService.mainApp` (macOS 13+) — the modern replacement for
/// LSSharedFileList login-item registration. No helper bundle is required.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    private let logger = Logger(subsystem: "com.zumix.jirafs", category: "LaunchAtLogin")

    /// Whether the app is currently registered as a login item.
    @Published private(set) var isEnabled: Bool = false

    init() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        // Auto-register on first launch (status == .notRegistered).
        // If the user previously disabled it (status == .notFound), do not re-register.
        if status == .notRegistered {
            registerIfNeeded()
        }
    }

    private func registerIfNeeded() {
        do {
            try SMAppService.mainApp.register()
            isEnabled = SMAppService.mainApp.status == .enabled
            logger.info("Auto-registered as login item")
        } catch {
            logger.warning("Auto-register as login item failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Registers or unregisters the app as a login item.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered as login item")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered as login item")
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            logger.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
