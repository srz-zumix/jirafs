import Foundation

/// Authenticates outgoing JIRA HTTP requests.
public protocol AuthProvider: Sendable {
    func authorize(_ request: inout URLRequest) async throws
}
