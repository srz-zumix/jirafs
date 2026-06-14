import Foundation
import AtlassianCore

/// Implements `JiraClient` against the JIRA REST API.
///
/// Cloud (v3) and Server (v2) only differ by base URL and version path; this
/// single implementation handles both via `JiraInstanceConfig.edition`.
public actor JiraRESTClient: JiraClient {
    public let config: JiraInstanceConfig
    private let auth: AuthProvider
    private let transport: JiraHTTPTransport
    private let decoder: JSONDecoder
    private let logger = JiraLog.logger("api")

    public init(
        config: JiraInstanceConfig,
        auth: AuthProvider,
        transport: JiraHTTPTransport = URLSessionTransport()
    ) {
        self.config = config
        self.auth = auth
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    // MARK: - JiraClient

    public func serverInfo() async throws {
        let _: JSONValue = try await get("serverInfo")
    }

    public func listProjects() async throws -> [JiraProject] {
        try await get("project")
    }

    public func getProject(key: String) async throws -> JiraProject {
        try await get("project/\(key)")
    }

    public func searchIssues(jql: String, nextPageToken: String?, maxResults: Int, fields: [String]?) async throws -> JiraSearchResult {
        if config.edition == .cloud {
            return try await searchIssuesCloud(jql: jql, nextPageToken: nextPageToken, maxResults: maxResults, fields: fields)
        } else {
            return try await searchIssuesServer(jql: jql, nextPageToken: nextPageToken, maxResults: maxResults, fields: fields)
        }
    }

    // Cloud v3: POST to search/jql, token-based pagination.
    private func searchIssuesCloud(jql: String, nextPageToken: String?, maxResults: Int, fields: [String]?) async throws -> JiraSearchResult {
        struct Body: Encodable {
            let jql: String
            let maxResults: Int
            let nextPageToken: String?
            let fields: [String]
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(jql, forKey: .jql)
                try c.encode(maxResults, forKey: .maxResults)
                if let token = nextPageToken { try c.encode(token, forKey: .nextPageToken) }
                try c.encode(fields, forKey: .fields)
            }
            enum CodingKeys: String, CodingKey { case jql, maxResults, nextPageToken, fields }
        }
        struct CloudResult: Decodable {
            let issues: [JiraIssue]
            let nextPageToken: String?
        }
        let fieldList: [String] = fields ?? [
            "summary", "status", "priority", "assignee", "reporter",
            "issuetype", "labels", "components", "created", "updated",
            "resolution", "parent", "subtasks", "issuelinks", "description"
        ]
        // Cloud caps maxResults at 100; clamp to avoid a 400 error.
        let cloudMaxResults = min(maxResults, 100)
        let body = Body(
            jql: jql,
            maxResults: cloudMaxResults,
            nextPageToken: nextPageToken,
            fields: fieldList
        )
        let url = try buildURL(path: "search/jql")
        let r: CloudResult = try await postDecoding(url: url, body: body)
        return JiraSearchResult(nextPageToken: r.nextPageToken, issues: r.issues)
    }

    // Server v2: GET search with startAt offset encoded in nextPageToken.
    private func searchIssuesServer(jql: String, nextPageToken: String?, maxResults: Int, fields: [String]?) async throws -> JiraSearchResult {
        struct ServerResult: Decodable {
            let startAt: Int
            let maxResults: Int
            let total: Int
            let issues: [JiraIssue]
        }
        let startAt = nextPageToken.flatMap(Int.init) ?? 0
        var items = [URLQueryItem]()
        items.append(URLQueryItem(name: "jql", value: jql))
        items.append(URLQueryItem(name: "startAt", value: String(startAt)))
        items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        // fields=nil → full field set; fields=[] → "-*" (no fields, key always returned)
        let fieldsValue = fields.map { $0.isEmpty ? "-*" : $0.joined(separator: ",") }
            ?? "summary,status,priority,assignee,reporter,issuetype,labels,components,created,updated,resolution,parent,subtasks,issuelinks,description"
        items.append(URLQueryItem(name: "fields", value: fieldsValue))
        let r: ServerResult = try await get("search", query: items)
        let nextOffset = startAt + r.issues.count
        let token = nextOffset < r.total ? String(nextOffset) : nil
        return JiraSearchResult(nextPageToken: token, issues: r.issues,
                                startAt: r.startAt, maxResults: r.maxResults, total: r.total)
    }

    public func getIssue(key: String) async throws -> JiraIssue {
        try await get("issue/\(key)")
    }

    public func listFields() async throws -> [JiraField] {
        try await get("field")
    }

    public func listComments(issueKey: String) async throws -> [JiraComment] {
        let list: JiraCommentList = try await get("issue/\(issueKey)/comment")
        return list.comments
    }

    public func listAttachments(issueKey: String) async throws -> [JiraAttachment] {
        // attachments live under `fields.attachment`, which we don't model in
        // `JiraIssueFields`. Decode a focused response struct directly.
        struct AttachmentResponse: Decodable {
            struct Fields: Decodable { let attachment: [JiraAttachment]? }
            let fields: Fields
        }
        let url = try buildURL(path: "issue/\(issueKey)", query: [URLQueryItem(name: "fields", value: "attachment")])
        let request = try await makeRequest(url: url)
        let (data, http) = try await transport.data(for: request)
        try validate(http: http, data: data)
        let decoded = try decoder.decode(AttachmentResponse.self, from: data)
        return decoded.fields.attachment ?? []
    }

    public func downloadAttachment(_ attachment: JiraAttachment, range: Range<Int>?) async throws -> Data {
        guard let contentURLString = attachment.content,
              let url = URL(string: contentURLString) else {
            throw JiraAPIError.invalidURL
        }
        // A compromised/malicious instance could return an attachment `content`
        // URL on an attacker-controlled host. Authorizing such a request would
        // leak the credentials (Basic email:token / Bearer PAT) to that host, so
        // only authorize URLs that point at the configured instance host.
        guard url.host?.lowercased() == config.baseURL.host?.lowercased() else {
            throw JiraAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try await auth.authorize(&request)
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        }
        let (data, http) = try await transport.data(for: request)
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, http: http)
        }
        return data
    }

    // MARK: - Internal

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let url = try buildURL(path: path, query: query)
        return try await sendDecoding(url: url)
    }

    private func postDecoding<T: Decodable, B: Encodable>(url: URL, body: B) async throws -> T {
        var request = try await makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await transport.data(for: request)
        try validate(http: http, data: data)
        logger.info("POST \(url.absoluteString, privacy: .public) status=\(http.statusCode)")
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("decode failure for \(url.absoluteString, privacy: .public): \(String(describing: error))")
            throw JiraAPIError.decoding(String(describing: error))
        }
    }

    private func sendDecoding<T: Decodable>(url: URL) async throws -> T {
        let request = try await makeRequest(url: url)
        let (data, http) = try await transport.data(for: request)
        try validate(http: http, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("decode failure for \(url.absoluteString, privacy: .public): \(String(describing: error))")
            throw JiraAPIError.decoding(String(describing: error))
        }
    }

    private func makeRequest(url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await auth.authorize(&request)
        return request
    }

    private func buildURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        // path may contain "?key=value" - split it out so we can append query items
        let (cleanPath, embeddedQuery): (String, [URLQueryItem]) = {
            if let mark = path.firstIndex(of: "?") {
                let after = path.index(after: mark)
                let queryString = String(path[after...])
                let items = queryString.split(separator: "&").compactMap { pair -> URLQueryItem? in
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard let k = kv.first else { return nil }
                    let v = kv.count > 1 ? String(kv[1]) : nil
                    return URLQueryItem(name: String(k), value: v)
                }
                return (String(path[..<mark]), items)
            }
            return (path, [])
        }()
        let basePath = "/rest/api/\(config.edition.apiVersion)/\(cleanPath)"
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw JiraAPIError.invalidURL
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + basePath
        let allItems = embeddedQuery + query
        if !allItems.isEmpty {
            components.queryItems = allItems
        }
        guard let url = components.url else { throw JiraAPIError.invalidURL }
        return url
    }

    private func validate(http: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
        logger.error("HTTP \(http.statusCode, privacy: .public) \(http.url?.absoluteString ?? "?", privacy: .public): \(body, privacy: .private)")
        throw mapError(status: http.statusCode, http: http)
    }

    private func mapError(status: Int, http: HTTPURLResponse) -> JiraAPIError {
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
