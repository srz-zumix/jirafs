import Foundation

/// JIRA Server / Data Center Personal Access Token (Bearer).
public struct PATAuth: AuthProvider {
    public let token: String

    public init(token: String) {
        self.token = token
    }

    public func authorize(_ request: inout URLRequest) async throws {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
