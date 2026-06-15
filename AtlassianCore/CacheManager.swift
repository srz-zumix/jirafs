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
/// AES-GCM-encrypted files under `cachesDir`.
/// - The master encryption key is supplied by the caller (resolved from the
///   shared data-protection Keychain via `KeychainManager.loadOrCreateCacheKey`)
///   and is **never** written to disk. Two purpose-specific keys are derived
///   from it with HKDF-SHA256: one for AES-GCM payload encryption and one for
///   the filename HMAC, so the same key material is not reused across
///   primitives.
/// - File names are `HMAC-SHA256(filenameKey, cacheKey)` (truncated), so they
///   are not guessable from a predictable `cacheKey` without the key, and no
///   path information is visible on disk.
/// - The cache directory is created with mode `0700`. Note: storing the
///   directory inside the FSKit extension's sandbox container only limits
///   access by *other sandboxed* apps; it is NOT a security boundary against
///   the same user, unsandboxed processes, Full Disk Access tools, backups, or
///   malware running with the user's privileges. The on-disk encryption exists
///   to avoid persisting API responses as plaintext, not to defend against an
///   attacker who can read the Keychain. Credentials live separately in the
///   Keychain; the disk cache only holds cached copies of API responses.
/// - If `diskEnabled` is requested but no encryption key is available (e.g. a
///   transient Keychain failure), the cache falls back to memory-only (logging
///   the condition). It never writes a plaintext key as a fallback.
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
    private let encryptionKey: SymmetricKey?   // HKDF-derived AES-GCM key
    private let filenameKey: SymmetricKey?     // HKDF-derived filename HMAC key

    // MARK: - Init

    /// Creates a `CacheManager`.
    ///
    /// - Parameters:
    ///   - diskEnabled: When `true`, entries are also persisted to disk.
    ///   - cachesDir:   Per-instance cache directory. The directory is created
    ///                  if it does not exist. Only used when `diskEnabled` is `true`.
    ///   - encryptionKey: Master key (from the Keychain) used to derive the
    ///                  disk encryption and filename keys. Required for disk
    ///                  persistence; if `nil`, the cache falls back to
    ///                  memory-only even when `diskEnabled` is `true`.
    public init(diskEnabled: Bool = false, cachesDir: URL? = nil,
                encryptionKey masterKey: SymmetricKey? = nil) {
        // Disk persistence requires ALL of: the flag, a directory, and a key.
        // Computing a single effective flag guarantees we never end up with a
        // cacheDir but no key (which would make evictExpiredDiskEntries treat
        // every file as undecryptable and delete it).
        let effective = diskEnabled && cachesDir != nil && masterKey != nil
        // Always purge a legacy plaintext key file when disk caching was
        // requested for this directory, even if we ultimately fall back to
        // memory-only — leaving old sensitive key material on disk would
        // contradict the migration guarantee.
        if diskEnabled, let dir = cachesDir {
            CacheManager.removeLegacyKeyFile(in: dir)
        }
        // Disk persistence further requires a usable directory. Creating it can
        // fail (permissions / I/O), and an already-existing directory may not be
        // writable, so probe writability after creation. If the directory cannot
        // be used, fall back to memory-only instead of pretending disk caching is
        // on while every write silently no-ops.
        var diskReady = effective
        if effective, let dir = cachesDir {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                // `createDirectory(attributes:)` only applies to directories it
                // actually creates, so re-assert 0700 in case an older build left
                // the directory world-readable.
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                let probe = dir.appendingPathComponent(".probe-\(UUID().uuidString)")
                try Data().write(to: probe, options: .atomic)
                try? FileManager.default.removeItem(at: probe)
            } catch {
                diskReady = false
                cacheLogger.error("CacheManager init: cache directory unusable; falling back to memory-only: \(String(describing: error))")
            }
        }
        if diskReady, let dir = cachesDir, let master = masterKey {
            self.diskEnabled = true
            self.cacheDir = dir
            self.encryptionKey = CacheManager.deriveKey(from: master, info: Self.encryptionKeyInfo)
            self.filenameKey = CacheManager.deriveKey(from: master, info: Self.filenameKeyInfo)
            cacheLogger.info("CacheManager init: diskEnabled=true (key from Keychain)")
        } else {
            // Only the missing-prerequisite case is reported here; a directory
            // failure already logged its own, more specific reason above.
            if diskEnabled && !effective {
                cacheLogger.error("CacheManager init: disk cache requested but unavailable; falling back to memory-only (cachesDirMissing=\(cachesDir == nil), encryptionKeyMissing=\(masterKey == nil))")
            }
            self.diskEnabled = false
            self.cacheDir = nil
            self.encryptionKey = nil
            self.filenameKey = nil
            cacheLogger.info("CacheManager init: diskEnabled=false")
        }
    }

    /// Stable, product-agnostic HKDF context labels. These are a compatibility
    /// boundary for the on-disk format: changing them changes the derived keys
    /// and invalidates existing `.cache` files, so they are versioned and must
    /// not be edited casually. `CacheManager` is shared by jirafs and
    /// confluencefs, so the labels are deliberately product-neutral.
    private static let encryptionKeyInfo = "com.zumix.atlassian.cache.encryption.v1"
    private static let filenameKeyInfo = "com.zumix.atlassian.cache.filename-hmac.v1"

    /// Derives a purpose-specific 256-bit key from the Keychain master key so
    /// that AES-GCM encryption and the filename HMAC never share key material.
    /// An empty salt is intentional: the master key is a uniformly random 256-bit
    /// Keychain key, so HKDF needs no salt to condition the input; purpose
    /// separation is provided entirely by the versioned `info` labels. Passing an
    /// explicit empty salt is byte-equivalent to the salt-less overload, so it
    /// does not change derived keys or the on-disk format.
    private static func deriveKey(from master: SymmetricKey, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data(),
                               info: Data(info.utf8), outputByteCount: 32)
    }

    /// Best-effort removal of the legacy plaintext `.cache.key` file from older
    /// versions that stored the key on disk next to the ciphertext.
    private static func removeLegacyKeyFile(in dir: URL) {
        let legacy = dir.appendingPathComponent(".cache.key")
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
            cacheLogger.info("removed legacy plaintext .cache.key")
        }
    }

    // MARK: - Static utilities

    /// Returns the per-instance cache directory URL (may not exist yet).
    public static func cacheDirectory(for instanceName: String, baseCachesDir: URL,
                                      product: String = "jirafs") -> URL {
        baseCachesDir.appendingPathComponent(product, isDirectory: true)
                     .appendingPathComponent(instanceName, isDirectory: true)
    }

    /// Returns the base product caches directory URL (may not exist yet).
    public static func baseCacheDirectory(baseCachesDir: URL, product: String = "jirafs") -> URL {
        baseCachesDir.appendingPathComponent(product, isDirectory: true)
    }

    /// Returns the caches base URL for the **current process**.
    ///
    /// Use this in both the host app and FSKit extensions.
    /// `FileManager.default.urls(for: .cachesDirectory)` resolves to the
    /// process's own `Library/Caches` directory regardless of whether the
    /// process is sandboxed (extension) or not (host app).
    public static func processCachesBaseURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Caches", isDirectory: true)
    }

    /// Deletes all cached files for the given instance.
    ///
    /// Safe to call from the host app. Constructs the path into the extension's
    /// sandbox container using `NSHomeDirectory()`, which is the real user home
    /// when called from the unsandboxed host app.
    ///
    /// - Returns: Number of files deleted.
    @discardableResult
    public static func clearCache(for instanceName: String, product: String = "jirafs",
                                  containerBundleID: String = "com.zumix.jirafs.fskit") -> Int {
        let baseCachesDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(containerBundleID)/Data/Library/Caches",
                                    isDirectory: true)
        let dir = cacheDirectory(for: instanceName, baseCachesDir: baseCachesDir, product: product)
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
            cacheLogger.info("getStale memHit: \(key, privacy: .private)")
            return v
        }
        guard diskEnabled else {
            cacheLogger.info("getStale diskDisabled: \(key, privacy: .private)")
            return nil
        }
        cacheLogger.info("getStale diskLookup: \(key, privacy: .private)")
        guard let (value, expiry): (T, Date) = diskGetStale(key: key) else {
            cacheLogger.info("getStale diskResult=nil key=\(key, privacy: .private)")
            return nil
        }
        cacheLogger.info("getStale diskResult=hit key=\(key, privacy: .private)")
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
        guard diskEnabled, let dir = cacheDir, encryptionKey != nil else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-staleWindow)
        for url in urls where url.pathExtension == "cache" {
            // A read failure (permissions / transient I/O) must NOT trigger a
            // delete — only act on files we could actually read.
            guard let envelope = try? Data(contentsOf: url) else { continue }
            if let expiry = diskExpiry(from: envelope) {
                if expiry < cutoff { try? fm.removeItem(at: url) }
            } else {
                // Readable but undecryptable with the current key: an orphan
                // left behind by an old plaintext-file key or an older filename
                // scheme. There is only one key per per-instance directory, so
                // this is safe to purge.
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Disk helpers

    /// On-disk format: `AES.GCM.SealedBox.combined` = nonce(12) + ciphertext + tag(16).
    /// The decrypted payload is: expiry(8, big-endian UInt64 unix timestamp) + JSON-encoded value.
    /// The expiry is inside the encrypted payload — it is NOT a plaintext field in the file.
    private func diskSet<T: Codable>(key: String, value: T, ttl: TimeInterval) {
        guard let dir = cacheDir, let encKey = encryptionKey, let nameKey = filenameKey else { return }
        guard let plaintext = try? JSONEncoder().encode(value) else { return }
        let expiry = Date().addingTimeInterval(ttl)
        var expiryBytes = UInt64(expiry.timeIntervalSince1970).bigEndian
        let expiryData = withUnsafeBytes(of: &expiryBytes) { Data($0) }
        let payload = expiryData + plaintext
        guard let sealed = try? AES.GCM.seal(payload, using: encKey) else { return }
        guard let combined = sealed.combined else { return }
        let fileURL = dir.appendingPathComponent(diskFileName(for: key, using: nameKey)).appendingPathExtension("cache")
        guard (try? combined.write(to: fileURL, options: .atomic)) != nil else { return }
        // Restrict to owner-only as defense in depth; the parent directory is
        // already 0700, but `write` honours the process umask (typically 0644).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func diskGet<T: Codable>(key: String) -> (value: T, expiresAt: Date)? {
        guard let dir = cacheDir, let encKey = encryptionKey, let nameKey = filenameKey else { return nil }
        let fileURL = dir.appendingPathComponent(diskFileName(for: key, using: nameKey)).appendingPathExtension("cache")
        guard let combined = try? Data(contentsOf: fileURL) else { return nil }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        guard let payload = try? AES.GCM.open(sealedBox, using: encKey) else { return nil }
        guard payload.count > 8 else { return nil }
        let expiryTimestamp = payload.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        let expiry = Date(timeIntervalSince1970: TimeInterval(expiryTimestamp))
        // Do NOT delete expired files here — diskGetStale() needs them for stale-while-revalidate.
        // Expired entries are cleaned up lazily by evictExpiredDiskEntries().
        guard expiry > Date() else { return nil }
        guard let value = try? JSONDecoder().decode(T.self, from: payload.dropFirst(8)) else { return nil }
        return (value, expiry)
    }

    /// Like `diskGet` but skips the expiry check — for stale-while-revalidate.
    private func diskGetStale<T: Codable>(key: String) -> (value: T, expiresAt: Date)? {
        guard let dir = cacheDir, let encKey = encryptionKey, let nameKey = filenameKey else {
            cacheLogger.info("diskGetStale: no dir or key for \(key, privacy: .private)")
            return nil
        }
        let fileURL = dir.appendingPathComponent(diskFileName(for: key, using: nameKey)).appendingPathExtension("cache")
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        cacheLogger.info("diskGetStale: file=\(fileURL.lastPathComponent, privacy: .public) exists=\(fileExists)")
        guard let combined = try? Data(contentsOf: fileURL) else {
            cacheLogger.info("diskGetStale: read failed for \(key, privacy: .private)")
            return nil
        }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else {
            cacheLogger.info("diskGetStale: sealedBox failed for \(key, privacy: .private)")
            return nil
        }
        guard let payload = try? AES.GCM.open(sealedBox, using: encKey) else {
            cacheLogger.info("diskGetStale: decrypt failed (wrong key?) for \(key, privacy: .private)")
            return nil
        }
        guard payload.count > 8 else { return nil }
        let expiryTimestamp = payload.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        let expiry = Date(timeIntervalSince1970: TimeInterval(expiryTimestamp))
        guard let decoded = try? JSONDecoder().decode(T.self, from: payload.dropFirst(8)) else {
            cacheLogger.info("diskGetStale: decode=fail for \(key, privacy: .private)")
            return nil
        }
        cacheLogger.info("diskGetStale: decode=ok for \(key, privacy: .private)")
        return (decoded, expiry)
    }

    private func diskRemove(key: String) {
        guard let dir = cacheDir, let nameKey = filenameKey else { return }
        let fileURL = dir.appendingPathComponent(diskFileName(for: key, using: nameKey)).appendingPathExtension("cache")
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
        let ts = payload.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// File name = first 32 hex chars of HMAC-SHA256(filenameKey, cacheKey).
    /// Keyed so it is not guessable from a predictable `cacheKey`, and not
    /// reversible.
    private func diskFileName(for key: String, using nameKey: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(key.utf8), using: nameKey)
        return mac.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Key management
    //
    // The disk cache's master key lives in the shared data-protection Keychain
    // (see KeychainManager.loadOrCreateCacheKey) and is passed into `init`. It
    // is never written to disk. The AES-GCM and filename-HMAC keys are derived
    // from it via HKDF-SHA256.
}
