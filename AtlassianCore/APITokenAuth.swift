import Foundation
import os

private let authLogger = Logger(subsystem: "com.zumix.jirafs", category: "auth")

/// Atlassian Cloud API Token (HTTP Basic with `email:token`).
public struct APITokenAuth: AuthProvider {
    public let email: String
    public let token: String

    public init(email: String, token: String) {
        self.email = email
        self.token = token
    }

    public func authorize(_ request: inout URLRequest) async throws {
        authLogger.debug("authorize: email=\(self.email, privacy: .private) token_len=\(self.token.count)")
        let raw = "\(email):\(token)"
        guard let data = raw.data(using: .utf8) else {
            throw AtlassianError.missingCredentials
        }
        let encoded = data.base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }
}
