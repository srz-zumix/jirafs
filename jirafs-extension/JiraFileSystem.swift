import Foundation
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
            let hostname = JiraFileSystem.hostname(from: resource, taskOptions: options.taskOptions)
            logger.info("loadResource hostname=\(hostname ?? "<unknown>", privacy: .public)")
            let (instanceName, config, auth, allowedProjectKeys, ttl, diskCacheEnabled, htmlEnabled) =
                try JiraFileSystem.lookupInstance(hostname: hostname)
            let client = JiraRESTClient(config: config, auth: auth)
            let cachesDir: URL? = {
                guard let base = try? FileManager.default.url(
                    for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                else { return nil }
                return CacheManager.cacheDirectory(for: instanceName, baseCachesDir: base)
            }()
            let cache = CacheManager(diskEnabled: diskCacheEnabled, cachesDir: cachesDir)
            if diskCacheEnabled {
                Task { await cache.evictExpiredDiskEntries() }
            }
            let dataSource = IssueDataSource(
                client: client,
                cache: cache,
                ttl: ttl,
                maxResults: 1000,
                allowedProjectKeys: allowedProjectKeys
            )
            let isReadOnly = true
            let volume = JiraVolume(name: instanceName, dataSource: dataSource, isReadOnly: isReadOnly, htmlEnabled: htmlEnabled)
            logger.info("loaded volume for \(instanceName, privacy: .public)")
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
        // URL ベースのマウントでは resource から hostname を KVC で取得し、
        // config.json の対応インスタンスを選択する。
        let hostname = JiraFileSystem.hostname(from: resource, taskOptions: [])
        logger.info("probeResource hostname=\(hostname ?? "<unknown>", privacy: .public)")
        let configURL = JiraFileSystem.configURL()
        let config = (try? Configuration.load(from: configURL)) ?? Configuration()
        let entry: Configuration.InstanceEntry?
        if let hostname {
            entry = config.instances.first { $0.url.host == hostname } ?? config.instances.first
        } else {
            entry = config.instances.first
        }
        let name = entry?.name ?? "jirafs"
        // Deterministic UUID keyed on the hostname (or instance name) so fskitd
        // recognises the same container across the probe → load state machine.
        // Using a random UUID causes EAGAIN because fskitd treats every attempt
        // as an unknown container and immediately closes it.
        let seedKey = hostname ?? name
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

    /// Extracts the JIRA hostname from the FSResource (via KVC) or from the
    /// raw taskOptions strings (looks for a "jira://" URL).
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

    static func firstInstance() -> Configuration.InstanceEntry? {
        let configURL = JiraFileSystem.configURL()
        let config = (try? Configuration.load(from: configURL)) ?? Configuration()
        return config.instances.first
    }

    static func deterministicUUID(for key: String) -> UUID {
        var bytes = Array<UInt8>(repeating: 0, count: 16)
        for (i, b) in Array(key.utf8).enumerated() { bytes[i % 16] ^= b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Resolve the instance matching `hostname` (falls back to the first entry).
    static func lookupInstance(hostname: String?) throws
        -> (String, JiraInstanceConfig, AuthProvider, [String]?,
            Configuration.CacheTTLConfig, Bool, Bool)
    {
        let configURL = JiraFileSystem.configURL()
        let config = (try? Configuration.load(from: configURL)) ?? Configuration()
        let entry: Configuration.InstanceEntry?
        if let hostname {
            entry = config.instances.first { $0.url.host == hostname } ?? config.instances.first
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
            let token = try keychain.password(instanceName: entry.name, account: email)
            auth = APITokenAuth(email: email, token: token)
        case .pat:
            let token = try keychain.password(instanceName: entry.name, account: "pat")
            auth = PATAuth(token: token)
        }
        return (entry.name, cfg, auth, entry.allowedProjectKeys,
                config.cache, entry.diskCache, entry.htmlView)
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
