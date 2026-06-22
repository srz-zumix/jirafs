import Foundation

/// Anonymous access: attaches no credentials. Used for public Atlassian sites
/// (e.g. a public Confluence space) that serve content without authentication.
///
/// The REST clients still enforce HTTPS before calling `authorize`, so using
/// `NoneAuth` keeps the no-cleartext guarantee while simply omitting the
/// `Authorization` header.
public struct NoneAuth: AuthProvider {
    public init() {}

    public func authorize(_ request: inout URLRequest) async throws {
        // Intentionally no-op: anonymous requests carry no Authorization header.
    }
}
