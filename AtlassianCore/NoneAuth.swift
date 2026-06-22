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
        // Anonymous requests carry no Authorization header. Actively clear any
        // header a caller may have pre-populated so credentials are never sent.
        request.setValue(nil, forHTTPHeaderField: "Authorization")
    }
}
