import Foundation
import Security
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
}
