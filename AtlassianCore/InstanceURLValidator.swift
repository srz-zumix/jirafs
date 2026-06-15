import Foundation

/// Validates that a URL returned by an Atlassian instance (e.g. an attachment
/// download link) is safe to authorize with the instance credentials.
///
/// Authorizing a request attaches the instance credentials (Basic
/// `email:token` or Bearer PAT). A compromised or malicious instance could
/// return a download link pointing somewhere other than the configured
/// instance, and authorizing it would leak those credentials. To prevent that,
/// a link is only accepted when it resolves to the **same origin** as the
/// configured base URL — identical scheme, host, and effective port — and
/// carries no embedded user-info.
public enum InstanceURLValidator {
    /// Resolves `link` (absolute or relative) against `base` and returns it only
    /// when it shares the same origin as `base`. Returns `nil` otherwise.
    ///
    /// Rejected cases include a different host, an `http://` downgrade of the
    /// same host, an alternate service on a different port, and any URL carrying
    /// embedded `user:password@` credentials. Relative links are resolved
    /// against `base` and then still origin-checked: path-relative links inherit
    /// `base`'s origin and pass, but network-path references like `//host/path`
    /// can resolve to a different host and are rejected.
    public static func sameOriginURL(_ link: String, base: URL) -> URL? {
        let resolved: URL?
        if let absolute = URL(string: link), absolute.scheme != nil {
            resolved = absolute
        } else {
            resolved = URL(string: link, relativeTo: base)?.absoluteURL
        }
        guard let url = resolved else { return nil }
        // Embedded user-info would be sent on the wire and can subvert auth /
        // logging expectations; never authorize such a URL.
        guard url.user == nil, url.password == nil else { return nil }
        guard sameOrigin(url, base) else { return nil }
        return url
    }

    /// Whether a request to `url` will travel over a secure (HTTPS) transport.
    ///
    /// Instance credentials (Basic `email:token` / Bearer PAT) must never be
    /// attached to a plaintext request, so callers gate `auth.authorize` on this
    /// check. It defends against a hand-edited `config.json` whose base URL was
    /// downgraded to `http://` even though the editor UI requires HTTPS.
    public static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let aScheme = a.scheme?.lowercased(),
              let bScheme = b.scheme?.lowercased(),
              aScheme == bScheme,
              let aHost = a.host?.lowercased(),
              let bHost = b.host?.lowercased(),
              aHost == bHost else {
            return false
        }
        return effectivePort(a) == effectivePort(b)
    }

    /// The port the request will actually connect to: the explicit port when
    /// present, otherwise the scheme's default. Comparing effective ports means
    /// `https://host` and `https://host:443` are treated as the same origin.
    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
