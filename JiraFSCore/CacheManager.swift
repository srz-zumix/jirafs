import Foundation
import CryptoKit
import os.log

private let cacheLogger = Logger(subsystem: "com.zumix.jirafs", category: "cache")

/// Async, TTL-based cache shared by the FSKit volume and clients.
///
/// **Memory layer** (always active): stores arbitrary `Codable & Sendable`
/// values keyed by string. Expired entries are evicted on access.
///
/// **Disk layer** (opt-in via `diskEnabled`): persists entries as
/// AES-GCM-encrypted files under `cachesDir/jirafs/`.
/// - The encryption key is stored as `.cache.key` (raw 32 bytes) inside the
///   cache directory. The directory is created with mode `0700` and the key
///   file with `0600` (owner-only read/write). When running as the FSKit
///   extension the directory is also inside the sandbox container, giving
///   defence-in-depth. On shared or non-sandboxed systems the POSIX
///   permissions are the primary access control.
///   Note: FSKit extensions run as system daemons and cannot call
///   `SecItemAdd`, so Keychain storage is not available in this context.
/// - File names are the SHA-256 hash of the cache key, so no JIRA path
///   information is visible on disk without the key.
///
/// `synchronize()` clears both layers (called from `FSVolume.synchronize`).
public actor CacheManager {

    // MARK: - Memory storage

    private struct Entry {
        let value: any Sendable
        let expiresAt: Date
    }
    private var storage: [String: Entry] = [:]

    // MARK: - Disk storage configuration

    private let diskEnabled: Bool
    private let cacheDir: URL?          // nil when diskEnabled == false
    private let encryptionKey: SymmetricKey?

    // MARK: - Init

    /// Creates a `CacheManager`.
    ///
    /// - Parameters:
    ///   - diskEnabled: When `true`, entries are also persisted to disk.
    ///   - cachesDir:   Per-instance cache directory. The directory is created
    ///                  if it does not exist. Only used when `diskEnabled` is `true`.
    public init(diskEnabled: Bool = false, cachesDir: URL? = nil) {
        self.diskEnabled = diskEnabled
        if diskEnabled, let dir = cachesDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            self.cacheDir = dir
            self.encryptionKey = CacheManager.loadOrCreateEncryptionKey(in: dir)
            cacheLogger.info("CacheManager init: diskEnabled=true hasKey=\(self.encryptionKey != nil)")
        } else {
            self.cacheDir = nil
            self.encryptionKey = nil
            cacheLogger.info("CacheManager init: diskEnabled=false")
        }
    }

    // MARK: - Static utilities

    /// Returns the per-instance cache directory URL (may not exist yet).
    public static func cacheDirectory(for instanceName: String, baseCachesDir: URL) -> URL {
        baseCachesDir.appendingPathComponent("jirafs", isDirectory: true)
                     .appendingPathComponent(instanceName, isDirectory: true)
    }

    /// Returns the base jirafs caches directory URL (may not exist yet).
    public static func baseCacheDirectory(baseCachesDir: URL) -> URL {
        baseCachesDir.appendingPathComponent("jirafs", isDirectory: true)
    }

    /// Returns the caches base URL of the FSKit extension container.
    ///
    /// The extension runs sandboxed under
    /// `~/Library/Containers/com.zumix.jirafs.fskit/Data/Library/Caches/`.
    /// Both the host app (unsandboxed) and the extension itself resolve to
    /// the same physical path using this helper.
    public static func extensionCachesBaseURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.zumix.jirafs.fskit/Data/Library/Caches",
                                    isDirectory: true)
    }

    /// Deletes all cached files for the given instance. Safe to call from the host app.
    /// - Returns: Number of files deleted.
    @discardableResult
    public static func clearCache(for instanceName: String) -> Int {
        let baseCachesDir = extensionCachesBaseURL()
        let dir = cacheDirectory(for: instanceName, baseCachesDir: baseCachesDir)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for url in urls where url.pathExtension == "cache" || url.lastPathComponent == ".cache.key" {
            if (try? FileManager.default.removeItem(at: url)) != nil { count += 1 }
        }
        cacheLogger.info("clearCache: deleted \(count) files for instance=\(instanceName, privacy: .public)")
        return count
    }

    // MARK: - Public API

    public func get<T: Codable & Sendable>(_ key: String, as type: T.Type) -> T? {
        // 1. Memory hit
        if let entry = storage[key] {
            // Fresh: return immediately.
            if entry.expiresAt > Date(), let v = entry.value as? T { return v }
            // Stale: keep entry in memory for getStale(); return nil so caller knows it's expired.
            return nil
        }
        // 2. Disk hit (only when disk cache enabled)
        guard diskEnabled else { return nil }
        guard let (value, expiry): (T, Date) = diskGet(key: key) else { return nil }
        storage[key] = Entry(value: value, expiresAt: expiry)
        return value
    }

    /// Returns a cached value **even if expired** (stale-while-revalidate).
    /// Returns `nil` only when no entry exists at all.
    public func getStale<T: Codable & Sendable>(_ key: String, as type: T.Type) -> T? {
        if let entry = storage[key], let v = entry.value as? T {
            cacheLogger.info("getStale memHit: \(key, privacy: .public)")
            return v
        }
        guard diskEnabled else {
            cacheLogger.info("getStale diskDisabled: \(key, privacy: .public)")
            return nil
        }
        cacheLogger.info("getStale diskLookup: \(key, privacy: .public)")
        guard let (value, expiry): (T, Date) = diskGetStale(key: key) else {
            cacheLogger.info("getStale diskResult=nil key=\(key, privacy: .public)")
            return nil
        }
        cacheLogger.info("getStale diskResult=hit key=\(key, privacy: .public)")
        storage[key] = Entry(value: value, expiresAt: expiry)
        return value
    }

    public func set<T: Codable & Sendable>(_ key: String, value: T, ttl: TimeInterval) {
        storage[key] = Entry(value: value, expiresAt: Date().addingTimeInterval(ttl))
        if diskEnabled {
            diskSet(key: key, value: value, ttl: ttl)
        }
    }

    // MARK: - Data overloads (Data is not Codable by itself in generic context)

    /// Values at or below this size are also kept in the memory cache for fast
    /// repeated reads (e.g. small icons, text files). Larger binaries are
    /// disk-only to avoid heap pressure from huge concurrent allocations
    /// alongside AES-GCM operations.
    static let dataMemoThreshold = 256 * 1024  // 256 KB

    public func get(_ key: String, as type: Data.Type) -> Data? {
        if let entry = storage[key] {
            if entry.expiresAt > Date(), let v = entry.value as? Data { return v }
            return nil
        }
        guard diskEnabled else { return nil }
        // Large binaries (> dataMemoThreshold) are disk-only; skip memory
        // repopulation to avoid heap pressure from large concurrent allocations.
        guard let (box, expiry): (DataBox, Date) = diskGet(key: key) else { return nil }
        guard let data = Data(base64Encoded: box.base64) else { return nil }
        if data.count <= Self.dataMemoThreshold {
            storage[key] = Entry(value: data, expiresAt: expiry)
        }
        return data
    }

    /// Returns a `Data` value even if expired (stale-while-revalidate).
    public func getStale(_ key: String, as type: Data.Type) -> Data? {
        if let entry = storage[key], let v = entry.value as? Data { return v }
        guard diskEnabled else { return nil }
        // Skip memory repopulation for the same reason as get(_:as:Data.Type).
        guard let (box, expiry): (DataBox, Date) = diskGetStale(key: key) else { return nil }
        guard let data = Data(base64Encoded: box.base64) else { return nil }
        if data.count <= Self.dataMemoThreshold {
            storage[key] = Entry(value: data, expiresAt: expiry)
        }
        return data
    }

    public func set(_ key: String, value: Data, ttl: TimeInterval) {
        let expiry = Date().addingTimeInterval(ttl)
        // Small values go into memory for fast repeated reads; large binaries
        // are disk-only to avoid heap pressure (see dataMemoThreshold).
        if value.count <= Self.dataMemoThreshold {
            storage[key] = Entry(value: value, expiresAt: expiry)
        }
        if diskEnabled {
            diskSet(key: key, value: DataBox(base64: value.base64EncodedString()), ttl: ttl)
        }
    }

    /// Thin `Codable` wrapper so `Data` can be serialised to disk.
    private struct DataBox: Codable { let base64: String }

    public func remove(_ key: String) {
        storage.removeValue(forKey: key)
        if diskEnabled { diskRemove(key: key) }
    }

    /// Clears memory cache and, if disk cache is enabled, all disk entries.
    public func synchronize() {
        storage.removeAll()
        if diskEnabled { diskClear() }
    }

    /// Removes expired disk entries.
    ///
    /// - Parameter staleWindow: Extra grace period after TTL expiry before a file is deleted.
    ///   Defaults to 7 days so stale-while-revalidate can use expired entries across remounts.
    public func evictExpiredDiskEntries(staleWindow: TimeInterval = 7 * 24 * 3600) {
        guard diskEnabled, let dir = cacheDir else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-staleWindow)
        for url in urls where url.pathExtension == "cache" {
            if let envelope = try? Data(contentsOf: url),
               let expiry = diskExpiry(from: envelope),
               expiry < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Disk helpers

    /// On-disk format: `AES.GCM.SealedBox.combined` = nonce(12) + ciphertext + tag(16).
    /// The decrypted payload is: expiry(8, big-endian UInt64 unix timestamp) + JSON-encoded value.
    /// The expiry is inside the encrypted payload — it is NOT a plaintext field in the file.
    private func diskSet<T: Codable>(key: String, value: T, ttl: TimeInterval) {
        guard let dir = cacheDir, let encKey = encryptionKey else { return }
        guard let plaintext = try? JSONEncoder().encode(value) else { return }
        let expiry = Date().addingTimeInterval(ttl)
        var expiryBytes = UInt64(expiry.timeIntervalSince1970).bigEndian
        let expiryData = withUnsafeBytes(of: &expiryBytes) { Data($0) }
        let payload = expiryData + plaintext
        guard let sealed = try? AES.GCM.seal(payload, using: encKey) else { return }
        guard let combined = sealed.combined else { return }
        let fileURL = dir.appendingPathComponent(diskFileName(for: key)).appendingPathExtension("cache")
        try? combined.write(to: fileURL, options: .atomic)
    }

    private func diskGet<T: Codable>(key: String) -> (value: T, expiresAt: Date)? {
        guard let dir = cacheDir, let encKey = encryptionKey else { return nil }
        let fileURL = dir.appendingPathComponent(diskFileName(for: key)).appendingPathExtension("cache")
        guard let combined = try? Data(contentsOf: fileURL) else { return nil }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        guard let payload = try? AES.GCM.open(sealedBox, using: encKey) else { return nil }
        guard payload.count > 8 else { return nil }
        let expiryTimestamp = payload.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let expiry = Date(timeIntervalSince1970: TimeInterval(expiryTimestamp))
        // Do NOT delete expired files here — diskGetStale() needs them for stale-while-revalidate.
        // Expired entries are cleaned up lazily by evictExpiredDiskEntries().
        guard expiry > Date() else { return nil }
        guard let value = try? JSONDecoder().decode(T.self, from: payload.dropFirst(8)) else { return nil }
        return (value, expiry)
    }

    /// Like `diskGet` but skips the expiry check — for stale-while-revalidate.
    private func diskGetStale<T: Codable>(key: String) -> (value: T, expiresAt: Date)? {
        guard let dir = cacheDir, let encKey = encryptionKey else {
            cacheLogger.info("diskGetStale: no dir or key for \(key, privacy: .public)")
            return nil
        }
        let fileURL = dir.appendingPathComponent(diskFileName(for: key)).appendingPathExtension("cache")
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        cacheLogger.info("diskGetStale: file=\(fileURL.lastPathComponent, privacy: .public) exists=\(fileExists)")
        guard let combined = try? Data(contentsOf: fileURL) else {
            cacheLogger.info("diskGetStale: read failed for \(key, privacy: .public)")
            return nil
        }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else {
            cacheLogger.info("diskGetStale: sealedBox failed for \(key, privacy: .public)")
            return nil
        }
        guard let payload = try? AES.GCM.open(sealedBox, using: encKey) else {
            cacheLogger.info("diskGetStale: decrypt failed (wrong key?) for \(key, privacy: .public)")
            return nil
        }
        guard payload.count > 8 else { return nil }
        let expiryTimestamp = payload.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let expiry = Date(timeIntervalSince1970: TimeInterval(expiryTimestamp))
        guard let decoded = try? JSONDecoder().decode(T.self, from: payload.dropFirst(8)) else {
            cacheLogger.info("diskGetStale: decode=fail for \(key, privacy: .public)")
            return nil
        }
        cacheLogger.info("diskGetStale: decode=ok for \(key, privacy: .public)")
        return (decoded, expiry)
    }

    private func diskRemove(key: String) {
        guard let dir = cacheDir else { return }
        let fileURL = dir.appendingPathComponent(diskFileName(for: key)).appendingPathExtension("cache")
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func diskClear() {
        guard let dir = cacheDir else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "cache" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func diskExpiry(from envelope: Data) -> Date? {
        guard let encKey = encryptionKey,
              let sealedBox = try? AES.GCM.SealedBox(combined: envelope),
              let payload = try? AES.GCM.open(sealedBox, using: encKey),
              payload.count > 8 else { return nil }
        let ts = payload.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// File name = first 32 hex chars of SHA-256(cacheKey). Not reversible.
    private func diskFileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Key management
    //
    // The 256-bit AES-GCM key is stored as a raw 32-byte file (.cache.key)
    // inside the cache directory. The directory is created with mode 0700 and
    // the key file itself is written with mode 0600 (owner-only read/write).
    // When running as the FSKit extension the directory is additionally inside
    // the macOS sandbox container. On shared or non-sandboxed systems the POSIX
    // permissions are the primary access control.
    // FSKit extensions run as system daemons and cannot call SecItemAdd,
    // making Keychain storage unavailable in this context.

    private static func loadOrCreateEncryptionKey(in dir: URL) -> SymmetricKey {
        let keyURL = dir.appendingPathComponent(".cache.key")
        if let keyData = try? Data(contentsOf: keyURL), keyData.count == 32 {
            cacheLogger.info("loadOrCreateEncryptionKey: loaded existing key")
            return SymmetricKey(data: keyData)
        }
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        do {
            try keyData.write(to: keyURL, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            cacheLogger.info("loadOrCreateEncryptionKey: generated and saved new key")
        } catch {
            cacheLogger.error("loadOrCreateEncryptionKey: write failed \(error, privacy: .public)")
        }
        return newKey
    }
}
