import Foundation

/// Authenticates outgoing Atlassian HTTP requests (JIRA / Confluence).
public protocol AuthProvider: Sendable {
    func authorize(_ request: inout URLRequest) async throws
}
