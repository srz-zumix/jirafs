import Foundation

/// Errors specific to the MCP (Model Context Protocol) transport, kept separate
/// from `AtlassianError` so callers can distinguish "the server has no such
/// tool" from a genuine HTTP/auth failure and fall back accordingly.
public enum MCPError: Error, Sendable, Equatable {
    /// The server replied with something that is not a valid JSON-RPC message.
    case protocolFailure(String)
    /// A JSON-RPC error object was returned (`-32601` = method not found).
    case rpc(code: Int, message: String)
    /// `tools/call` succeeded at the protocol level but reported `isError: true`.
    case toolFailed(String)
    /// The tool refused the caller's credentials (e.g. the organization has not
    /// enabled API-token access to the MCP server).
    case accessDenied(String)
    /// None of the tools this client needs are exposed by the server.
    case noUsableTool
}

/// Minimal MCP client speaking JSON-RPC 2.0 over the Streamable HTTP transport.
///
/// Only the subset needed to invoke a remote tool is implemented: `initialize`
/// (plus the `notifications/initialized` acknowledgement), `tools/list` and
/// `tools/call`. Responses may arrive either as a plain JSON object or as an
/// SSE stream carrying one, so both encodings are decoded.
///
/// Authorization is delegated to `AuthProvider`, so the same credentials used
/// for the REST APIs (Atlassian API token → HTTP Basic) authenticate the MCP
/// session.
public actor MCPClient {
    public struct Tool: Sendable, Equatable {
        public let name: String
        public let description: String?
        public let inputSchema: JSONValue
    }

    public struct ToolResult: Sendable, Equatable {
        public let text: String
        public let isError: Bool
    }

    /// MCP revision advertised during `initialize` and in `MCP-Protocol-Version`.
    public static let protocolVersion = "2025-06-18"

    /// Upper bound on a single response body that this client will *accept and
    /// parse*. Note this is a protocol acceptance limit, not a memory bound:
    /// `HTTPTransport.data(for:)` fully materialises the response before this
    /// check runs, so it caps how large a document we attempt to decode rather
    /// than how many bytes `URLSession` may buffer. Enforcing a true streaming
    /// byte limit would require a bounded-reader transport abstraction.
    public static let maxResponseBytes = 8 * 1024 * 1024

    /// Upper bound on `tools/list` pages followed via `nextCursor`.
    public static let maxToolPages = 20

    public let endpoint: URL
    private let auth: AuthProvider
    private let transport: HTTPTransport
    private let clientName: String
    private let clientVersion: String
    private let logger = AtlassianLog.logger("mcp")

    private var sessionID: String?
    private var handshake: Task<Void, Error>?
    private var nextID = 1

    public init(
        endpoint: URL,
        auth: AuthProvider,
        transport: HTTPTransport = URLSessionTransport(),
        clientName: String = "jirafs",
        clientVersion: String = "1.0"
    ) {
        self.endpoint = endpoint
        self.auth = auth
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    // MARK: - Tools

    public func listTools() async throws -> [Tool] {
        var tools: [Tool] = []
        var cursor: String?
        // Servers may paginate; bail out rather than follow a cursor loop forever.
        for _ in 0..<Self.maxToolPages {
            let params: JSONValue = cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            let result = try await call(method: "tools/list", params: params)
            let raw = result.objectValue?["tools"]?.arrayValue ?? []
            tools += raw.compactMap { item in
                guard let obj = item.objectValue, let name = obj["name"]?.stringValue else { return nil }
                return Tool(
                    name: name,
                    description: obj["description"]?.stringValue,
                    inputSchema: obj["inputSchema"] ?? .null
                )
            }
            guard let next = result.objectValue?["nextCursor"]?.stringValue, !next.isEmpty else { break }
            cursor = next
        }
        return tools
    }

    public func callTool(name: String, arguments: [String: JSONValue]) async throws -> ToolResult {
        let result = try await call(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ]))
        let obj = result.objectValue ?? [:]
        let blocks = obj["content"]?.arrayValue ?? []
        let text = blocks
            .compactMap { $0.objectValue?["text"]?.stringValue }
            .joined(separator: "\n")
        return ToolResult(text: text, isError: obj["isError"]?.boolValue ?? false)
    }

    // MARK: - JSON-RPC plumbing

    /// Sends a request, performing the `initialize` handshake first. A dropped
    /// server-side session (HTTP 404 for a session we believed was live) is
    /// retried once with a fresh handshake.
    private func call(method: String, params: JSONValue) async throws -> JSONValue {
        try await ensureHandshake()
        do {
            return try await send(method: method, params: params)
        } catch AtlassianError.notFound where sessionID != nil {
            logger.debug("mcp session expired; re-initializing")
            handshake = nil
            sessionID = nil
            try await ensureHandshake()
            return try await send(method: method, params: params)
        }
    }

    private func ensureHandshake() async throws {
        if let handshake {
            try await handshake.value
            return
        }
        let task = Task { try await self.performHandshake() }
        handshake = task
        do {
            try await task.value
        } catch {
            handshake = nil
            throw error
        }
    }

    private func performHandshake() async throws {
        _ = try await send(method: "initialize", params: .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ]))
        try await notify(method: "notifications/initialized")
    }

    private func send(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let body = try JSONEncoder().encode(RPCRequest(id: id, method: method, params: params))
        let (data, http) = try await perform(body: body)
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            sessionID = session
        }
        try validate(http: http, data: data, method: method)
        return try decodeResult(from: data, http: http)
    }

    private func notify(method: String) async throws {
        let body = try JSONEncoder().encode(RPCRequest(id: nil, method: method, params: nil))
        let (data, http) = try await perform(body: body)
        try validate(http: http, data: data, method: method)
    }

    private func perform(body: Data) async throws -> (Data, HTTPURLResponse) {
        // The endpoint carries the API-token credentials, so refuse to authorize
        // an insecure transport or a URL that smuggles credentials via user-info
        // (mirrors the HTTPS enforcement the REST clients apply before signing).
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.user == nil, endpoint.password == nil else {
            throw AtlassianError.invalidURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        try await auth.authorize(&request)
        let (data, http) = try await transport.data(for: request)
        guard data.count <= Self.maxResponseBytes else {
            throw MCPError.protocolFailure("response larger than \(Self.maxResponseBytes) bytes")
        }
        return (data, http)
    }

    private func validate(http: HTTPURLResponse, data: Data, method: String) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
        logger.error("""
            mcp HTTP \(http.statusCode, privacy: .public) \
            \(method, privacy: .public) \(self.endpoint.absoluteString, privacy: .public): \
            \(snippet, privacy: .private)
            """)
        switch http.statusCode {
        case 401: throw AtlassianError.unauthorized
        case 403: throw AtlassianError.forbidden
        case 404: throw AtlassianError.notFound
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AtlassianError.rateLimited(retryAfter: retry)
        case 500...599: throw AtlassianError.serverError(status: http.statusCode)
        default: throw AtlassianError.transport("mcp HTTP \(http.statusCode)")
        }
    }

    private func decodeResult(from data: Data, http: HTTPURLResponse) throws -> JSONValue {
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let payloads = contentType.contains("text/event-stream")
            ? MCPClient.sseDataPayloads(data)
            : [data]
        let decoder = JSONDecoder()
        for payload in payloads {
            guard let envelope = try? decoder.decode(RPCResponse.self, from: payload) else { continue }
            if let error = envelope.error {
                throw MCPError.rpc(code: error.code, message: error.message)
            }
            if let result = envelope.result {
                return result
            }
        }
        throw MCPError.protocolFailure("no JSON-RPC result in response")
    }

    /// Extracts the `data:` payload of every SSE event in `data`. Multi-line
    /// `data:` fields are re-joined with newlines as the SSE spec requires.
    static func sseDataPayloads(_ data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var payloads: [Data] = []
        var lines: [String] = []
        func flush() {
            guard !lines.isEmpty else { return }
            payloads.append(Data(lines.joined(separator: "\n").utf8))
            lines.removeAll()
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            if line.isEmpty {
                flush()
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            var value = String(line.dropFirst("data:".count))
            if value.hasPrefix(" ") { value.removeFirst() }
            lines.append(value)
        }
        flush()
        return payloads
    }

    private struct RPCRequest: Encodable {
        let jsonrpc = "2.0"
        let id: Int?
        let method: String
        let params: JSONValue?
    }

    private struct RPCResponse: Decodable {
        struct Failure: Decodable {
            let code: Int
            let message: String
        }
        let result: JSONValue?
        let error: Failure?
    }
}
