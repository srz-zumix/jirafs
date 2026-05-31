import Foundation

/// Errors thrown by Atlassian API clients (JIRA / Confluence).
/// Mapped to `POSIXError` at the FSKit boundary.
public enum AtlassianError: Error, Sendable, Equatable {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case decoding(String)
    case transport(String)
    case missingCredentials
    case unsupported
}
