import Foundation
import JiraAPI
import JiraFSCore
import ConfluenceFSCore

/// Persists the host app's `AppStore` (servers + mounts) and derives the
/// per-extension `config.json` files the FSKit extensions read.
///
/// - The `AppStore` (source of truth) lives in the **host app's** Application
///   Support directory (`~/Library/Application Support/jirafs/appstore.json`).
/// - The derived `config.json` files are written into each **extension's**
///   sandbox container so the sandboxed extension can read them without an App
///   Group. The host app (no sandbox) can write there directly.
enum AppConfig {
    /// Bundle ID of the JIRA FSKit extension (= its sandbox container name).
    private static let extensionBundleID = "com.zumix.jirafs.fskit"
    /// Bundle ID of the Confluence FSKit extension (= its sandbox container name).
    private static let confluenceExtensionBundleID = "com.zumix.jirafs.confluencefs.fskit"

    // MARK: - AppStore (source of truth)

    /// Path to the host app's `appstore.json`.
    static func appStoreURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("jirafs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("appstore.json")
    }

    static func loadAppStore() -> AppStore {
        (try? AppStore.load(from: appStoreURL())) ?? AppStore()
    }

    /// Saves the `AppStore` and regenerates both derived `config.json` files so
    /// the extensions immediately see the new servers/mounts.
    static func saveAppStore(_ store: AppStore) throws {
        try store.save(to: appStoreURL())
        try save(deriveJira(from: store))
        try saveConfluence(deriveConfluence(from: store))
    }

    // MARK: - Derivation

    static func deriveJira(from store: AppStore) -> Configuration {
        let entries: [Configuration.InstanceEntry] = store.mounts.compactMap { mount in
            guard mount.product == .jira,
                  let server = store.server(id: mount.serverID),
                  let conn = server.jira else { return nil }
            let auth = Configuration.AuthEntry(
                method: jiraMethod(server.auth.method),
                email: server.auth.method == .apiToken ? server.auth.email : nil
            )
            return Configuration.InstanceEntry(
                mountID: mount.id,
                serverID: server.id,
                name: mount.name,
                type: conn.edition,
                url: conn.url,
                auth: auth,
                mountPath: mount.mountPath,
                allowedProjectKeys: mount.allowedKeys,
                diskCache: mount.diskCache,
                htmlView: mount.htmlView,
                autoMount: mount.autoMount
            )
        }
        return Configuration(instances: entries,
                             cache: store.jiraCache,
                             pagination: store.jiraPagination)
    }

    static func deriveConfluence(from store: AppStore) -> ConfluenceConfiguration {
        let entries: [ConfluenceConfiguration.InstanceEntry] = store.mounts.compactMap { mount in
            guard mount.product == .confluence,
                  let server = store.server(id: mount.serverID),
                  let conn = server.confluence else { return nil }
            // Normalize Cloud URLs: strip a trailing `/wiki` (or `/wiki/`) that
            // may have been saved by an older build. The REST client adds
            // `/wiki/api/v2/` automatically, so the base URL must be the site root.
            let resolvedURL: URL
            if conn.edition == .cloud {
                let raw = conn.url.absoluteString
                let stripped = raw.hasSuffix("/wiki/") ? String(raw.dropLast(6))
                             : raw.hasSuffix("/wiki")  ? String(raw.dropLast(5))
                             : raw
                resolvedURL = URL(string: stripped) ?? conn.url
            } else {
                resolvedURL = conn.url
            }
            let auth = ConfluenceConfiguration.AuthEntry(
                method: confluenceMethod(server.auth.method),
                email: server.auth.method == .apiToken ? server.auth.email : nil
            )
            return ConfluenceConfiguration.InstanceEntry(
                mountID: mount.id,
                serverID: server.id,
                name: mount.name,
                type: conn.edition,
                url: resolvedURL,
                auth: auth,
                mountPath: mount.mountPath,
                allowedSpaceKeys: mount.allowedKeys,
                diskCache: mount.diskCache,
                htmlView: mount.htmlView,
                includeArchived: mount.includeArchived,
                includeRestricted: mount.includeRestricted,
                autoMount: mount.autoMount
            )
        }
        return ConfluenceConfiguration(instances: entries,
                                       cache: store.confluenceCache,
                                       pagination: store.confluencePagination)
    }

    private static func jiraMethod(_ m: ServerAuthMethod) -> Configuration.AuthEntry.Method {
        m == .apiToken ? .apiToken : .pat
    }

    private static func confluenceMethod(_ m: ServerAuthMethod) -> ConfluenceConfiguration.AuthEntry.Method {
        m == .apiToken ? .apiToken : .pat
    }

    // MARK: - Derived config files (written into extension containers)

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

    static func save(_ config: Configuration) throws {
        try config.save(to: configURL())
    }

    static func saveConfluence(_ config: ConfluenceConfiguration) throws {
        try config.save(to: confluenceConfigURL())
    }
}
