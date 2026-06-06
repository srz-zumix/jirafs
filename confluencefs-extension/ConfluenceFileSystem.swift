import Foundation
import CryptoKit
import FSKit
import AtlassianCore
import ConfluenceAPI
import ConfluenceFSCore
import os

/// Top-level `FSUnaryFileSystem` that resolves a `confluence://` URL into a
/// `ConfluenceVolume`.
@available(macOS 15.4, *)
@objc(ConfluenceFileSystem)
final class ConfluenceFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    let logger = AtlassianLog.logger("confluence-filesystem")

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, Error?) -> Void
    ) {
        do {
            self.containerStatus = .ready
            let mountID = ConfluenceFileSystem.hostname(from: resource, taskOptions: options.taskOptions)
            logger.info("loadResource mountID=\(mountID ?? "<unknown>", privacy: .public)")
            let (volumeName, cacheID, config, auth, allowedSpaceKeys, ttl, pagination, diskCacheEnabled, htmlEnabled, includeArchived) =
                try ConfluenceFileSystem.lookupInstance(mountID: mountID)
            let client = ConfluenceRESTClient(config: config, auth: auth)
            let cachesDir: URL? = diskCacheEnabled
                ? CacheManager.cacheDirectory(for: cacheID,
                                              baseCachesDir: CacheManager.processCachesBaseURL(),
                                              product: "confluencefs")
                : nil
            let encryptionKey: SymmetricKey?
            if diskCacheEnabled {
                do {
                    encryptionKey = try KeychainManager().loadOrCreateCacheKey(instanceName: cacheID, product: "confluencefs")
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
            let dataSource = PageDataSource(
                client: client,
                cache: cache,
                ttl: ttl,
                limit: pagination.limit,
                allowedSpaceKeys: allowedSpaceKeys,
                includeArchived: includeArchived
            )
            let volume = ConfluenceVolume(name: volumeName, dataSource: dataSource, isReadOnly: true, htmlEnabled: htmlEnabled)
            logger.info("loaded volume for \(volumeName, privacy: .public)")
            reply(volume, nil)
        } catch {
            logger.error("loadResource failed: \(error, privacy: .public)")
            reply(nil, FSKitError.from(error))
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        self.containerStatus = .ready
        reply(nil)
    }

    func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
        let mountID = ConfluenceFileSystem.hostname(from: resource, taskOptions: [])
        logger.info("probeResource mountID=\(mountID ?? "<unknown>", privacy: .public)")
        let configURL = ConfluenceFileSystem.configURL()
        let config = (try? ConfluenceConfiguration.load(from: configURL)) ?? ConfluenceConfiguration()
        let entry: ConfluenceConfiguration.InstanceEntry?
        if let mountID {
            entry = config.instances.first { $0.mountID == mountID } ?? config.instances.first
        } else {
            entry = config.instances.first
        }
        let name = entry?.name ?? "confluencefs"
        let seedKey = mountID ?? name
        let containerID = FSContainerIdentifier(uuid: ConfluenceFileSystem.deterministicUUID(for: seedKey))
        self.containerStatus = .ready
        reply(.usable(name: name, containerID: containerID), nil)
    }

    func didFinishLoading() {
        logger.info("ConfluenceFileSystem loaded")
    }

    // MARK: - Configuration lookup

    static func hostname(from resource: FSResource, taskOptions: [String]) -> String? {
        if resource.responds(to: NSSelectorFromString("url")),
           let url = (resource as AnyObject).value(forKey: "url") as? URL,
           let host = url.host {
            return host
        }
        for opt in taskOptions {
            if let url = URL(string: opt), url.scheme == "confluence", let host = url.host {
                return host
            }
        }
        return nil
    }

    static func deterministicUUID(for key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3f) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2],  bytes[3],
                           bytes[4], bytes[5], bytes[6],  bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Resolve the mount matching `mountID` (falls back to the first entry).
    static func lookupInstance(mountID: String?) throws
        -> (String, String, ConfluenceInstanceConfig, AuthProvider, [String]?,
            ConfluenceConfiguration.CacheTTLConfig, ConfluenceConfiguration.Pagination, Bool, Bool, Bool)
    {
        let configURL = ConfluenceFileSystem.configURL()
        let config = (try? ConfluenceConfiguration.load(from: configURL)) ?? ConfluenceConfiguration()
        let entry: ConfluenceConfiguration.InstanceEntry?
        if let mountID {
            entry = config.instances.first { $0.mountID == mountID } ?? config.instances.first
        } else {
            entry = config.instances.first
        }
        guard let entry else { throw AtlassianError.missingCredentials }
        let keychain = KeychainManager()
        let cfg = ConfluenceInstanceConfig(name: entry.name, baseURL: entry.url, edition: entry.type)
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
        }
        return (entry.name, entry.mountID, cfg, auth, entry.allowedSpaceKeys,
                config.cache, config.pagination, entry.diskCache, entry.htmlView, entry.includeArchived)
    }

    static func configURL() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("confluencefs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }
}
