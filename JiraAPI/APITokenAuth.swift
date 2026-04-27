import Foundation

/// JIRA Cloud API Token (HTTP Basic with `email:token`).
public struct APITokenAuth: AuthProvider {
    public let email: String
    public let token: String

    public init(email: String, token: String) {
        self.email = email
        self.token = token
    }

    public func authorize(_ request: inout URLRequest) async throws {
        let raw = "\(email):\(token)"
        guard let data = raw.data(using: .utf8) else {
            throw JiraAPIError.missingCredentials
        }
        let encoded = data.base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }
}
