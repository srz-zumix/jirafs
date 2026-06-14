import Foundation
import Security
import CryptoKit
import os

private let keychainLogger = Logger(subsystem: "com.zumix.jirafs", category: "keychain")

/// Wraps Keychain access for jirafs / confluencefs credentials.
///
/// Items live in the shared Keychain Access Group so the host app and the
/// FSKit extension can both read them.
public struct KeychainManager: Sendable {
    /// The shared Keychain access group, resolved at runtime from the process's own
    /// embedded entitlements (`keychain-access-groups`). This means the correct
    /// team prefix is used regardless of which developer/team signs the binary.
    /// Falls back to the original hard-coded value if entitlement reading fails
    /// (e.g. in unit-test targets that run without a signing identity).
    public static let accessGroup: String = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "keychain-access-groups" as CFString, nil),
              let groups = value as? [String],
              let group = groups.first(where: { $0.hasSuffix(".com.zumix.jirafs.shared") })
        else {
            return "KPZ4FUM7GD.com.zumix.jirafs.shared"
        }
        return group
    }()
    public static let servicePrefix = "com.zumix.jirafs"

    public init() {}

    public func service(forInstance instanceName: String) -> String {
        "\(Self.servicePrefix).\(instanceName)"
    }

    /// Keychain service name for a server's shared credentials. Servers are
    /// keyed by a stable UUID so several mounts can reuse one credential and so
    /// renaming a server never orphans its stored token.
    public func service(forServer serverID: String) -> String {
        "\(Self.servicePrefix).server.\(serverID)"
    }

    /// Store a credential against a server (shared by all of its mounts).
    public func setServerPassword(_ password: String, serverID: String, account: String) throws {
        try setPassword(password, service: service(forServer: serverID), account: account)
    }

    /// Read a server credential. Used by both the host app and the extension.
    public func serverPassword(serverID: String, account: String) throws -> String {
        try password(service: service(forServer: serverID), account: account)
    }

    /// Remove a server credential (used when the server is deleted).
    public func deleteServerPassword(serverID: String, account: String) throws {
        try delete(service: service(forServer: serverID), account: account)
    }

    public func setPassword(
        _ password: String,
        instanceName: String,
        account: String
    ) throws {
        try setPassword(password, service: service(forInstance: instanceName), account: account)
    }

    /// Core write keyed directly by Keychain `service`.
    public func setPassword(
        _ password: String,
        service: String,
        account: String
    ) throws {
        guard let data = password.data(using: .utf8) else {
            throw AtlassianError.missingCredentials
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Re-assert accessibility on every update so credentials written by
            // an older build (which used `kSecAttrAccessibleAfterFirstUnlock`,
            // eligible for iCloud Keychain / backups) are migrated to the
            // device-only class rather than retaining the looser one.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AtlassianError.transport("Keychain add failed: \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            throw AtlassianError.transport("Keychain update failed: \(updateStatus)")
        }
    }

    public func password(instanceName: String, account: String) throws -> String {
        try password(service: service(forInstance: instanceName), account: account)
    }

    /// Core read keyed directly by Keychain `service`.
    public func password(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        keychainLogger.debug("lookup: service=\(service, privacy: .public) account=\(account, privacy: .private) group=\(Self.accessGroup, privacy: .public)")
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        keychainLogger.debug("lookup status: \(status, privacy: .public)")
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                keychainLogger.error("Keychain item not found: service=\(service, privacy: .public) account=\(account, privacy: .private)")
                throw AtlassianError.missingCredentials
            }
            keychainLogger.error("Keychain read failed: \(status, privacy: .public)")
            throw AtlassianError.transport("Keychain read failed: \(status)")
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw AtlassianError.missingCredentials
        }
        return string
    }

    public func delete(instanceName: String, account: String) throws {
        try delete(service: service(forInstance: instanceName), account: account)
    }

    /// Core delete keyed directly by Keychain `service`.
    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw AtlassianError.transport("Keychain delete failed: \(status)")
        }
    }

    // MARK: - Disk-cache encryption key
    //
    // The disk cache's master encryption key is stored in the shared
    // data-protection Keychain (same access group as credentials), NOT as a
    // plaintext file next to the encrypted cache. Both the host app and the
    // FSKit extension can read/create it because they share the access group.
    // The item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the
    // extension can use it without any user-presence prompt, while keeping the
    // key off iCloud Keychain and device backups (it never leaves this Mac).

    private static let cacheKeyAccount = "cache_encryption_key"

    /// Keychain service name for an instance's cache key. The instance name is
    /// hashed (with the product folded in) so that names containing `.`, case
    /// differences, or other characters do not break the service string and
    /// are extremely unlikely to collide — the suffix is a truncated SHA-256,
    /// so collisions are theoretically possible but negligibly improbable. The
    /// product fold-in keeps jirafs / confluencefs instances of the same name
    /// on distinct keys even though they share one access group.
    private static func cacheKeyService(product: String, instanceName: String) -> String {
        let digest = SHA256.hash(data: Data("\(product)|\(instanceName)".utf8))
        let suffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(servicePrefix).cachekey.\(suffix)"
    }

    /// Loads the per-instance disk-cache master key from the shared Keychain,
    /// creating and storing a new random 256-bit key only when none exists.
    ///
    /// A new key is generated **exclusively** on `errSecItemNotFound`. Any other
    /// Keychain error is thrown rather than treated as "absent", so a transient
    /// read failure can never silently rotate the key and invalidate existing
    /// cache files.
    public func loadOrCreateCacheKey(instanceName: String, product: String) throws -> SymmetricKey {
        let service = Self.cacheKeyService(product: product, instanceName: instanceName)
        if let data = try readCacheKeyData(service: service) {
            // The key may have been created by an older build with the looser
            // `kSecAttrAccessibleAfterFirstUnlock` (eligible for iCloud Keychain
            // / backups). Best-effort migrate it to the device-only class in
            // place. A failure here must never break decryption of an
            // already-readable key, so the status is intentionally ignored; an
            // in-place update also avoids a delete+re-add race between the host
            // app and the extension.
            migrateCacheKeyAccessibility(service: service)
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.cacheKeyAccount,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: keyData,
        ]
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Another process (host app / extension) created it concurrently.
            guard let data = try readCacheKeyData(service: service) else {
                throw AtlassianError.transport("Keychain cache-key vanished after duplicate")
            }
            return SymmetricKey(data: data)
        }
        guard status == errSecSuccess else {
            throw AtlassianError.transport("Keychain cache-key add failed: \(status)")
        }
        return key
    }

    /// Returns the stored 32-byte key, `nil` only on `errSecItemNotFound`.
    /// Throws on any other Keychain error so callers never misread a failure as
    /// "no key" and regenerate.
    private func readCacheKeyData(service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.cacheKeyAccount,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AtlassianError.transport("Keychain cache-key read failed: \(status)")
        }
        guard let data = item as? Data, data.count == 32 else {
            throw AtlassianError.transport("Keychain cache-key has unexpected size")
        }
        return data
    }

    /// Best-effort, in-place migration of an existing cache-key item to the
    /// device-only accessibility class. Older builds created the key with
    /// `kSecAttrAccessibleAfterFirstUnlock` (eligible for iCloud Keychain /
    /// backups); re-asserting the device-only class enforces "never leaves this
    /// Mac" on upgrade. Any failure is ignored so it can never break reads of an
    /// already-accessible key, and an in-place `SecItemUpdate` avoids a
    /// delete+re-add race between the host app and the extension.
    private func migrateCacheKeyAccessibility(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.cacheKeyAccount,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        _ = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    /// Deletes the stored cache key for an instance (used when the instance is
    /// removed). Clearing cache *files* alone does not delete the key.
    public func deleteCacheKey(instanceName: String, product: String) throws {
        let service = Self.cacheKeyService(product: product, instanceName: instanceName)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.cacheKeyAccount,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw AtlassianError.transport("Keychain cache-key delete failed: \(status)")
        }
    }
}
