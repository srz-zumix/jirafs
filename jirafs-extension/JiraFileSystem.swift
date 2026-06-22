import Foundation
import CryptoKit
import FSKit
import JiraAPI
import JiraFSCore
import os

/// Top-level `FSUnaryFileSystem` that resolves a `jira://` URL into a
/// `JiraVolume`.
@available(macOS 15.4, *)
@objc(JiraFileSystem)
final class JiraFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    let logger = JiraLog.logger("filesystem")

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, Error?) -> Void
    ) {
        do {
            // For URL-based resources (jira://), fskitd skips probeResource and
            // calls loadResource directly. FSKit requires containerStatus == .ready
            // before it processes the reply(volume:) call, so we ensure it here.
            // (If probeResource was called it already set .ready; this is idempotent.)
            self.containerStatus = .ready
            let mountID = JiraFileSystem.hostname(from: resource, taskOptions: options.taskOptions)
            logger.info("loadResource mountID=\(mountID ?? "<unknown>", privacy: .public)")
            let (volumeName, cacheID, config, auth, allowedProjectKeys, ttl, pagination, diskCacheEnabled, htmlEnabled) =
                try JiraFileSystem.lookupInstance(mountID: mountID)
            let client = JiraRESTClient(config: config, auth: auth)
            let cachesDir: URL? = diskCacheEnabled
                ? CacheManager.cacheDirectory(for: cacheID,
                                              baseCachesDir: CacheManager.processCachesBaseURL())
                : nil
            let encryptionKey: SymmetricKey?
            if diskCacheEnabled {
                do {
                    encryptionKey = try KeychainManager().loadOrCreateCacheKey(instanceName: cacheID, product: "jirafs")
                } catch {
                    encryptionKey = nil
                    logger.error("disk cache enabled but cache key unavailable; using memory-only cache: \(String(describing: error), privacy: .public)")
                }
            } else {
                encryptionKey = nil
            }
            let cache = CacheManager(diskEnabled: diskCacheEnabled, cachesDir: cachesDir,
                                     encryptionKey: encryptionKey)
            if diskCacheEnabled {
                Task { await cache.evictExpiredDiskEntries() }
            }
            let dataSource = IssueDataSource(
                client: client,
                cache: cache,
                ttl: ttl,
                maxResults: pagination.maxResults,
                allowedProjectKeys: allowedProjectKeys
            )
            let isReadOnly = true
            let volume = JiraVolume(name: volumeName, dataSource: dataSource, isReadOnly: isReadOnly, htmlEnabled: htmlEnabled)
            logger.info("loaded volume for \(volumeName, privacy: .public)")
            // FSKit automatically transitions containerStatus notReady → active
            // when reply(volume, nil) is called. Do NOT set it manually here
            // or FSKit reports "unexpected container state".
            reply(volume, nil)
        } catch {
            logger.error("loadResource failed: \(error, privacy: .public)")
            reply(nil, FSKitError.from(error))
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        // Reset to ready so fskitd can re-probe and re-load the same containerID
        // on a subsequent mount without needing a fskitd restart.
        self.containerStatus = .ready
        reply(nil)
    }

    func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
        // URL ベースのマウントでは resource から mountID (URL host) を KVC で取得し、
        // config.json の対応マウントを選択する。
        let mountID = JiraFileSystem.hostname(from: resource, taskOptions: [])
        logger.info("probeResource mountID=\(mountID ?? "<unknown>", privacy: .public)")
        let configURL = JiraFileSystem.configURL()
        let config = (try? Configuration.load(from: configURL)) ?? Configuration()
        let entry: Configuration.InstanceEntry?
        if let mountID {
            entry = config.instances.first { $0.mountID == mountID } ?? config.instances.first
        } else {
            entry = config.instances.first
        }
        let name = entry?.name ?? "jirafs"
        // Deterministic UUID keyed on the mountID (or instance name) so fskitd
        // recognises the same container across the probe → load state machine.
        // Using a random UUID causes EAGAIN because fskitd treats every attempt
        // as an unknown container and immediately closes it.
        let seedKey = mountID ?? name
        let containerID = FSContainerIdentifier(uuid: JiraFileSystem.deterministicUUID(for: seedKey))
        // Transition notReady → ready so that fskitd can subsequently call
        // loadResource. FSKit requires the container to be in "ready" state
        // before it will invoke loadResource; without this, loadResource fails
        // with EAGAIN ("unexpected container state").
        self.containerStatus = .ready
        reply(.usable(name: name, containerID: containerID), nil)
    }

    func didFinishLoading() {
        logger.info("JiraFileSystem loaded")
    }

    // MARK: - Configuration lookup

    /// Extracts the mount identifier (carried as the URL host of the
    /// `jira://<mountID>` mount URL) from the FSResource (via KVC) or from the
    /// raw taskOptions strings.
    static func hostname(from resource: FSResource, taskOptions: [String]) -> String? {
        // Approach 1: FSResource may carry a URL property (non-public API).
        // Use KVC so we don't crash if the property doesn't exist.
        if resource.responds(to: NSSelectorFromString("url")),
           let url = (resource as AnyObject).value(forKey: "url") as? URL,
           let host = url.host {
            return host
        }
        // Approach 2: scan taskOptions for a "jira://<host>" string.
        for opt in taskOptions {
            if let url = URL(string: opt), url.scheme == "jira", let host = url.host {
                return host
            }
        }
        return nil
    }

    static func deterministicUUID(for key: String) -> UUID {
        // Derive a UUID from SHA-256 so different keys have negligible collision risk.
        // Version/variant bits are set per RFC 4122 §4.3 (name-based UUID, version 5).
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3f) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2],  bytes[3],
                           bytes[4], bytes[5], bytes[6],  bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Resolve the mount matching `mountID` (falls back to the first entry).
    /// Returns `(volumeName, cacheID, config, auth, allowedProjectKeys, ttl, pagination, diskCache, htmlView)`.
    /// Credentials are read from the Keychain by the mount's `serverID`; the
    /// disk cache is namespaced by the mount's `mountID` (`cacheID`).
    static func lookupInstance(mountID: String?) throws
        -> (String, String, JiraInstanceConfig, AuthProvider, [String]?,
            Configuration.CacheTTLConfig, Configuration.Pagination, Bool, Bool)
    {
        let configURL = JiraFileSystem.configURL()
        let config = (try? Configuration.load(from: configURL)) ?? Configuration()
        let entry: Configuration.InstanceEntry?
        if let mountID {
            entry = config.instances.first { $0.mountID == mountID } ?? config.instances.first
        } else {
            entry = config.instances.first
        }
        guard let entry else { throw JiraAPIError.missingCredentials }
        let keychain = KeychainManager()
        let cfg = JiraInstanceConfig(name: entry.name, baseURL: entry.url, edition: entry.type)
        let auth: AuthProvider
        switch entry.auth.method {
        case .apiToken:
            let email = entry.auth.email ?? ""
            let account = email.isEmpty ? "api_token" : email
            let token = try keychain.serverPassword(serverID: entry.serverID, account: account)
            auth = APITokenAuth(email: email, token: token)
        case .pat:
            let token = try keychain.serverPassword(serverID: entry.serverID, account: "pat")
            auth = PATAuth(token: token)
        case .none:
            auth = NoneAuth()
        }
        return (entry.name, entry.mountID, cfg, auth, entry.allowedProjectKeys,
                config.cache, config.pagination, entry.diskCache, entry.htmlView)
    }

    static func configURL() -> URL {
        let fm = FileManager.default
        // The extension is sandboxed; applicationSupportDirectory resolves to
        // ~/Library/Containers/com.zumix.jirafs.fskit/Data/Library/Application Support/
        // The host app writes here directly (no sandbox on host side).
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("jirafs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }
}
