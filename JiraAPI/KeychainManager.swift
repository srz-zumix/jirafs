import Foundation
import Security

/// Wraps Keychain access for jirafs credentials.
///
/// Items live in the shared Keychain Access Group so the host app and the
/// FSKit extension can both read them.
public struct KeychainManager: Sendable {
    public static let accessGroup = "com.zumix.jirafs.shared"
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
            throw JiraAPIError.missingCredentials
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Self.accessGroup,
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
                throw JiraAPIError.transport("Keychain add failed: \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            throw JiraAPIError.transport("Keychain update failed: \(updateStatus)")
        }
    }

    public func password(instanceName: String, account: String) throws -> String {
        let service = service(forInstance: instanceName)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw JiraAPIError.missingCredentials
            }
            throw JiraAPIError.transport("Keychain read failed: \(status)")
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw JiraAPIError.missingCredentials
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
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw JiraAPIError.transport("Keychain delete failed: \(status)")
        }
    }
}
