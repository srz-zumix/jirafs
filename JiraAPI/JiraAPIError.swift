import Foundation

/// Errors thrown by the JIRA API client. Mapped to `POSIXError` at the FSKit boundary.
public enum JiraAPIError: Error, Sendable, Equatable {
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
