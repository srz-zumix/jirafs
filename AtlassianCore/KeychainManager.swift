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

    public func setPassword(
        _ password: String,
        instanceName: String,
        account: String
    ) throws {
        let service = service(forInstance: instanceName)
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
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AtlassianError.transport("Keychain add failed: \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            throw AtlassianError.transport("Keychain update failed: \(updateStatus)")
        }
    }

    public func password(instanceName: String, account: String) throws -> String {
        let service = service(forInstance: instanceName)
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
        let service = service(forInstance: instanceName)
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
    // The item is `kSecAttrAccessibleAfterFirstUnlock` so the extension can use
    // it without any user-presence prompt.

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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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
