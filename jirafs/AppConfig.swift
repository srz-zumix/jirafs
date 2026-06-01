import Foundation
import JiraAPI
import JiraFSCore
import ConfluenceFSCore

/// Resolves the config.json shared between the host app and the FSKit extension.
///
/// The extension runs sandboxed under `com.zumix.jirafs.fskit` and reads its
/// own container via the standard `applicationSupportDirectory` API.
/// The host app has no sandbox, so it can write directly to the extension's
/// container — no App Group entitlement required.
enum AppConfig {
    /// Bundle ID of the JIRA FSKit extension (= its sandbox container name).
    private static let extensionBundleID = "com.zumix.jirafs.fskit"
    /// Bundle ID of the Confluence FSKit extension (= its sandbox container name).
    private static let confluenceExtensionBundleID = "com.zumix.jirafs.confluencefs.fskit"

    static func configURL() -> URL {
        resolveConfigURL(extensionBundleID: extensionBundleID, product: "jirafs")
    }

    /// Resolve the Confluence extension's config.json path.
    static func confluenceConfigURL() -> URL {
        resolveConfigURL(extensionBundleID: confluenceExtensionBundleID, product: "confluencefs")
    }

    private static func resolveConfigURL(extensionBundleID: String, product: String) -> URL {
        let fm = FileManager.default
        // Target the extension's sandboxed Application Support directory.
        // The host app (no sandbox) can access this path directly.
        let extDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Containers/\(extensionBundleID)/Data/Library/Application Support/\(product)",
                isDirectory: true)
        if (try? fm.createDirectory(at: extDir, withIntermediateDirectories: true)) != nil
            || fm.fileExists(atPath: extDir.path) {
            return extDir.appendingPathComponent("config.json")
        }
        // Fallback (first launch before extension container is created).
        let fallback = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let fallbackDir = fallback.appendingPathComponent(product, isDirectory: true)
        try? fm.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        return fallbackDir.appendingPathComponent("config.json")
    }

    static func load() -> Configuration {
        (try? Configuration.load(from: configURL())) ?? Configuration()
    }

    static func save(_ config: Configuration) throws {
        try config.save(to: configURL())
    }

    static func loadConfluence() -> ConfluenceConfiguration {
        (try? ConfluenceConfiguration.load(from: confluenceConfigURL())) ?? ConfluenceConfiguration()
    }

    static func saveConfluence(_ config: ConfluenceConfiguration) throws {
        try config.save(to: confluenceConfigURL())
    }
}
