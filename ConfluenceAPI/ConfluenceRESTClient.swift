import Foundation
import AtlassianCore

/// Implements `ConfluenceClient` against the Confluence REST API.
///
/// Cloud speaks REST v2 (`/wiki/api/v2/`, cursor pagination) and Data Center
/// speaks REST v1 (`/rest/api/`, start/limit pagination). The two dialects are
/// bridged onto the shared `Confluence*` domain models here.
public actor ConfluenceRESTClient: ConfluenceClient {
    public let config: ConfluenceInstanceConfig
    private let auth: AuthProvider
    private let transport: HTTPTransport
    private let decoder: JSONDecoder
    private let logger = AtlassianLog.logger("confluence-api")

    /// Expand string that fetches restriction subjects (user + group) for both
    /// read and update operations. Used in DC list requests and Cloud v1 content.
    private static let restrictionsExpand = [
        "restrictions.read.restrictions.user",
        "restrictions.read.restrictions.group",
        "restrictions.update.restrictions.user",
        "restrictions.update.restrictions.group"
    ].joined(separator: ",")

    public init(
        config: ConfluenceInstanceConfig,
        auth: AuthProvider,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.config = config
        self.auth = auth
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    // MARK: - ConfluenceClient

    public func listSpaces(cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceSpace> {
        if config.edition.isCloud {
            let page: CloudList<CloudSpace> = try await cloudGet("spaces", cursor: cursor, limit: limit)
            return ConfluencePageList(items: page.results.map { $0.domain }, nextCursor: page.cursor)
        } else {
            let page: DCList<DCSpace> = try await dcGet("space", cursor: cursor, limit: limit)
            return mapDC(page) { $0.domain }
        }
    }

    public func listRootPages(space: ConfluenceSpace, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluencePage> {
        // Always filter to status=current to exclude archived pages.
        let statusQuery = [URLQueryItem(name: "status", value: "current")]
        if config.edition.isCloud {
            let page: CloudList<CloudPage> = try await cloudGet(
                "spaces/\(space.id)/pages",
                cursor: cursor, limit: limit,
                extraQuery: [URLQueryItem(name: "depth", value: "root")] + statusQuery
            )
            return ConfluencePageList(items: page.results.map { $0.domain(format: nil) }, nextCursor: page.cursor)
        } else {
            let page: DCList<DCPage> = try await dcGet(
                "space/\(space.key)/content/page",
                cursor: cursor, limit: limit,
                extraQuery: [URLQueryItem(name: "depth", value: "root"),
                             URLQueryItem(name: "expand", value: Self.restrictionsExpand)] + statusQuery
            )
            return mapDC(page) { $0.domain }
        }
    }

    public func listArchivedRootPages(space: ConfluenceSpace, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluencePage> {
        let statusQuery = [URLQueryItem(name: "status", value: "archived")]
        if config.edition.isCloud {
            let page: CloudList<CloudPage> = try await cloudGet(
                "spaces/\(space.id)/pages",
                cursor: cursor, limit: limit,
                extraQuery: [URLQueryItem(name: "depth", value: "root")] + statusQuery
            )
            return ConfluencePageList(items: page.results.map { $0.domain(format: nil) }, nextCursor: page.cursor)
        } else {
            let page: DCList<DCPage> = try await dcGet(
                "space/\(space.key)/content/page",
                cursor: cursor, limit: limit,
                extraQuery: [URLQueryItem(name: "depth", value: "root"),
                             URLQueryItem(name: "expand", value: Self.restrictionsExpand)] + statusQuery
            )
            return mapDC(page) { $0.domain }
        }
    }

    public func listChildPages(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluencePage> {
        let statusQuery = [URLQueryItem(name: "status", value: "current")]
        if config.edition.isCloud {
            let page: CloudList<CloudPage> = try await cloudGet("pages/\(pageId)/children", cursor: cursor, limit: limit, extraQuery: statusQuery)
            return ConfluencePageList(items: page.results.map { $0.domain(format: nil) }, nextCursor: page.cursor)
        } else {
            let page: DCList<DCPage> = try await dcGet(
                "content/\(pageId)/child/page",
                cursor: cursor, limit: limit,
                extraQuery: statusQuery + [URLQueryItem(name: "expand", value: Self.restrictionsExpand)]
            )
            return mapDC(page) { $0.domain }
        }
    }

    public func listArchivedChildPages(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluencePage> {
        let statusQuery = [URLQueryItem(name: "status", value: "archived")]
        if config.edition.isCloud {
            let page: CloudList<CloudPage> = try await cloudGet("pages/\(pageId)/children", cursor: cursor, limit: limit, extraQuery: statusQuery)
            return ConfluencePageList(items: page.results.map { $0.domain(format: nil) }, nextCursor: page.cursor)
        } else {
            let page: DCList<DCPage> = try await dcGet(
                "content/\(pageId)/child/page",
                cursor: cursor, limit: limit,
                extraQuery: statusQuery + [URLQueryItem(name: "expand", value: Self.restrictionsExpand)]
            )
            return mapDC(page) { $0.domain }
        }
    }

    public func getPage(id: String, bodyFormat: ConfluenceBodyFormat) async throws -> ConfluencePage {
        if config.edition.isCloud {
            let query = [URLQueryItem(name: "body-format", value: bodyFormat.rawValue)]
            let page: CloudPage = try await sendDecoding(url: try cloudURL("pages/\(id)", query: query))
            return page.domain(format: bodyFormat)
        } else {
            // DC only supports storage; ADF is Cloud-only.
            let expand = "body.storage,version,space,ancestors,history"
            let query = [URLQueryItem(name: "expand", value: expand)]
            let page: DCPage = try await sendDecoding(url: try dcURL("content/\(id)", query: query))
            return page.domain
        }
    }

    public func listComments(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceComment> {
        if config.edition.isCloud {
            let query = [URLQueryItem(name: "body-format", value: ConfluenceBodyFormat.storage.rawValue)]
            let page: CloudList<CloudComment> = try await cloudGet("pages/\(pageId)/footer-comments", cursor: cursor, limit: limit, extraQuery: query)
            return ConfluencePageList(items: page.results.map { $0.domain }, nextCursor: page.cursor)
        } else {
            let query = [URLQueryItem(name: "expand", value: "body.storage,history,version")]
            let page: DCList<DCComment> = try await dcGet("content/\(pageId)/child/comment", cursor: cursor, limit: limit, extraQuery: query)
            return mapDC(page) { $0.domain }
        }
    }

    public func listAttachments(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceAttachment> {
        if config.edition.isCloud {
            let page: CloudList<CloudAttachment> = try await cloudGet("pages/\(pageId)/attachments", cursor: cursor, limit: limit)
            return ConfluencePageList(items: page.results.map { $0.domain }, nextCursor: page.cursor)
        } else {
            let page: DCList<DCAttachment> = try await dcGet("content/\(pageId)/child/attachment", cursor: cursor, limit: limit)
            return mapDC(page) { $0.domain }
        }
    }

    public func listLabels(pageId: String, cursor: String?, limit: Int) async throws -> ConfluencePageList<ConfluenceLabel> {
        if config.edition.isCloud {
            let page: CloudList<CloudLabel> = try await cloudGet("pages/\(pageId)/labels", cursor: cursor, limit: limit)
            return ConfluencePageList(items: page.results.map { $0.domain }, nextCursor: page.cursor)
        } else {
            let page: DCList<DCLabel> = try await dcGet("content/\(pageId)/label", cursor: cursor, limit: limit)
            return mapDC(page) { $0.domain }
        }
    }

    public func downloadAttachment(_ attachment: ConfluenceAttachment, range: Range<Int>?) async throws -> Data {
        guard let link = attachment.downloadLink, let url = resolveURL(link) else {
            throw AtlassianError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try await authorize(&request)
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        }
        let (data, http) = try await transport.data(for: request)
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, http: http)
        }
        return data
    }

    public func attachmentSize(_ attachment: ConfluenceAttachment) async throws -> Int? {
        guard let link = attachment.downloadLink, let url = resolveURL(link) else {
            throw AtlassianError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        try await authorize(&request)
        let (_, http) = try await transport.data(for: request)
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, http: http)
        }
        guard let value = http.value(forHTTPHeaderField: "Content-Length"),
              let size = Int(value.trimmingCharacters(in: .whitespaces)),
              size >= 0 else {
            return nil
        }
        return size
    }

    public func restrictedRootPageIDs(spaceKey: String, status: String, limiter: RateLimiter) async throws -> Set<String> {
        // Data Center: restriction data is embedded inline via `expand` in list responses.
        guard config.edition.isCloud else { return [] }
        // Cloud: v1 Space content API scoped to depth=root — fetches only the
        // root pages of this space, not the entire page tree.
        let baseQuery: [URLQueryItem] = [
            URLQueryItem(name: "depth",  value: "root"),
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "expand", value: Self.restrictionsExpand)
        ]
        return try await v1PaginatedRestrictedIDs(path: "space/\(spaceKey)/content/page",
                                                  baseQuery: baseQuery,
                                                  limiter: limiter)
    }

    public func restrictedChildPageIDs(pageId: String, status: String, limiter: RateLimiter) async throws -> Set<String> {
        // Data Center: restriction data is embedded inline via `expand` in list responses.
        guard config.edition.isCloud else { return [] }
        // Cloud: v1 child page API for this specific parent — only the direct
        // children are scanned, not the entire space.
        let baseQuery: [URLQueryItem] = [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "expand", value: Self.restrictionsExpand)
        ]
        return try await v1PaginatedRestrictedIDs(path: "content/\(pageId)/child/page",
                                                  baseQuery: baseQuery,
                                                  limiter: limiter)
    }

    /// Paginates a Cloud v1 API endpoint with `start`/`limit` and collects the
    /// IDs of items where `restrictions.hasAny == true`. Each page request is
    /// routed through `limiter` so 429 / server-error retries and backoff are
    /// applied independently per page.
    private func v1PaginatedRestrictedIDs(
        path: String,
        baseQuery: [URLQueryItem],
        limiter: RateLimiter
    ) async throws -> Set<String> {
        let limit = 50
        var start = 0
        var restricted = Set<String>()
        while true {
            var query = baseQuery
            query.append(URLQueryItem(name: "start", value: String(start)))
            query.append(URLQueryItem(name: "limit", value: String(limit)))
            let url = try cloudV1URL(path, query: query)
            let page: V1ContentList = try await limiter.run {
                try await self.sendDecoding(url: url)
            }
            for item in page.results where item.restrictions?.hasAny == true {
                restricted.insert(item.id)
            }
            let size = page.size ?? page.results.count
            // A short page is always the last page.
            if size < limit { break }
            // A full page with an explicit `next == nil` (the `_links` envelope is
            // present but carries no next link) is the last page. When the
            // `_links` envelope is absent entirely we cannot conclude there are no
            // more pages, so keep paging by `start`/`size` until a short page.
            if let links = page.links, links.next == nil { break }
            start += size
        }
        return restricted
    }

    // MARK: - Cloud (v2) helpers

    private func cloudGet<T: Decodable>(
        _ path: String,
        cursor: String?,
        limit: Int,
        extraQuery: [URLQueryItem] = []
    ) async throws -> CloudList<T> {
        var query = extraQuery
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await sendDecoding(url: try cloudURL(path, query: query))
    }

    private func cloudURL(_ path: String, query: [URLQueryItem]) throws -> URL {
        try buildURL(basePath: "/wiki/api/v2/\(path)", query: query)
    }

    /// Cloud v1 REST API URL builder: `/wiki/rest/api/{path}`.
    private func cloudV1URL(_ path: String, query: [URLQueryItem]) throws -> URL {
        try buildURL(basePath: "/wiki/rest/api/\(path)", query: query)
    }

    // MARK: - Data Center (v1) helpers

    private func dcGet<T: Decodable>(
        _ path: String,
        cursor: String?,
        limit: Int,
        extraQuery: [URLQueryItem] = []
    ) async throws -> DCList<T> {
        var query = extraQuery
        let start = cursor.flatMap(Int.init) ?? 0
        query.append(URLQueryItem(name: "start", value: String(start)))
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        return try await sendDecoding(url: try dcURL(path, query: query))
    }

    private func dcURL(_ path: String, query: [URLQueryItem]) throws -> URL {
        try buildURL(basePath: "/rest/api/\(path)", query: query)
    }

    /// Bridges a Data Center paginated response onto `ConfluencePageList`,
    /// encoding the next-page cursor as the next `start` offset.
    private func mapDC<Wire, Element: Sendable>(
        _ page: DCList<Wire>,
        _ transform: (Wire) -> Element
    ) -> ConfluencePageList<Element> {
        let start = page.start ?? 0
        let size = page.size ?? page.results.count
        let limit = page.limit ?? size
        // Prefer the server-provided `_links.next`: when the envelope is present
        // its absence reliably marks the last page. Only fall back to the
        // size>=limit heuristic when no links envelope was returned at all.
        let hasNext: Bool
        if let links = page.links {
            hasNext = links.next != nil
        } else {
            hasNext = limit > 0 && size >= limit
        }
        let nextCursor = hasNext ? String(start + size) : nil
        return ConfluencePageList(items: page.results.map(transform), nextCursor: nextCursor)
    }

    // MARK: - Networking

    private func sendDecoding<T: Decodable>(url: URL) async throws -> T {
        let request = try await makeRequest(url: url)
        let (data, http) = try await transport.data(for: request)
        try validate(http: http, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("decode failure for \(url.absoluteString, privacy: .public): \(String(describing: error))")
            throw AtlassianError.decoding(String(describing: error))
        }
    }

    private func makeRequest(url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await authorize(&request)
        return request
    }

    /// Attaches the instance credentials, but only over HTTPS. Centralizing the
    /// scheme check here guarantees credentials are never sent in cleartext,
    /// even if `config.baseURL` was hand-edited to `http://` in `config.json`.
    private func authorize(_ request: inout URLRequest) async throws {
        guard let url = request.url, InstanceURLValidator.isSecure(url) else {
            throw AtlassianError.invalidURL
        }
        try await auth.authorize(&request)
    }

    private func buildURL(basePath: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw AtlassianError.invalidURL
        }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + basePath
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AtlassianError.invalidURL }
        return url
    }

    /// Resolves a possibly-relative link (e.g. `/download/attachments/...`)
    /// against the instance base URL.
    ///
    /// Returns `nil` for any URL that does not resolve to the configured
    /// instance origin (same scheme, host, and port). A compromised/malicious
    /// instance could otherwise return an attachment download link on an
    /// attacker-controlled origin; authorizing that request would leak the
    /// credentials (Basic email:token / Bearer PAT) to the third-party origin.
    /// This also blocks `http://` downgrades, alternate-port services, and
    /// user-info URLs on the same host. Relative links resolve against
    /// `config.baseURL` and are then still origin-checked: path-relative links
    /// inherit the instance origin, but network-path references like
    /// `//host/path` can resolve elsewhere and are rejected.
    private func resolveURL(_ link: String) -> URL? {
        InstanceURLValidator.sameOriginURL(link, base: config.baseURL)
    }

    private func validate(http: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
        logger.error("HTTP \(http.statusCode, privacy: .public) \(http.url?.absoluteString ?? "?", privacy: .public): \(body, privacy: .private)")
        throw mapError(status: http.statusCode, http: http)
    }

    private func mapError(status: Int, http: HTTPURLResponse) -> AtlassianError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default: return .serverError(status: status)
        }
    }
}
