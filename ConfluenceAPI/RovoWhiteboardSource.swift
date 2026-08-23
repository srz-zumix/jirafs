import Foundation
import AtlassianCore

/// Fetches Confluence whiteboard content through the Atlassian Rovo MCP server.
///
/// The Confluence REST API exposes only whiteboard *metadata* — the canvas is
/// not retrievable. Rovo MCP surfaces it through the Teamwork Graph tools
/// (`read:whiteboard:confluence`), which return an LLM-oriented text rendering
/// of the board.
///
/// Those tools are **beta** and their argument names are not contractual, so the
/// tool and its URL-taking parameter are discovered from `tools/list` at runtime
/// (once per mount) rather than hard-coded. Cloud only.
public actor RovoWhiteboardSource {
    /// Atlassian's hosted MCP endpoint (API-token authentication variant).
    public static let defaultEndpoint = URL(string: "https://mcp.atlassian.com/v1/mcp")!

    /// Tools that can return whiteboard content, in preference order.
    static let candidateTools = ["getTeamworkGraphObject", "fetchAtlassian", "getTeamworkGraphContext"]

    /// How the discovered tool is invoked. The Teamwork Graph tools take a
    /// tenant `cloudId` plus their own object locator, so they cannot be driven
    /// by the generic single-parameter form.
    enum Binding: Sendable, Equatable {
        /// `getTeamworkGraphObject(cloudId:objects:)`
        case graphObject(tool: String)
        /// `getTeamworkGraphContext(cloudId:objectIdentifier:objectType:)`
        case graphContext(tool: String)
        /// Any other tool that takes the object URL in a single parameter.
        case locator(tool: String, parameter: String, wrapsInArray: Bool)

        var tool: String {
            switch self {
            case .graphObject(let tool), .graphContext(let tool), .locator(let tool, _, _): return tool
            }
        }
    }

    /// How the whiteboard is addressed in the tool arguments. The Teamwork Graph
    /// tools accept either form, and which one resolves varies per board.
    enum LocatorForm: Sendable, Equatable {
        case webURL
        case ari
    }

    private let mcp: MCPClient
    private let siteBaseURL: URL
    private let transport: HTTPTransport
    /// Binding that has actually returned content; pinned after the first success.
    private var binding: Binding?
    /// Locator form that last resolved; tried first on subsequent reads.
    private var locatorForm: LocatorForm?
    private var candidates: [Binding]?
    private var cachedCloudID: String?
    /// Set once the server is known to expose no usable tool, so the file system
    /// does not re-run discovery on every failed read.
    private var unsupported: MCPError?
    private var discovery: Task<[Binding], Error>?
    private let logger = AtlassianLog.logger("rovo-whiteboard")

    public init(mcp: MCPClient, siteBaseURL: URL, transport: HTTPTransport = URLSessionTransport()) {
        self.mcp = mcp
        self.siteBaseURL = siteBaseURL
        self.transport = transport
    }

    /// Text rendering of the whiteboard canvas, or throws when Rovo exposes no
    /// tool able to resolve it.
    public func content(for whiteboard: ConfluenceWhiteboard) async throws -> String {
        guard let url = absoluteWebURL(whiteboard.webURL) else { throw AtlassianError.notFound }
        var failure: Error?
        for candidate in try await resolveBindings() {
            for form in orderedLocatorForms(for: candidate) {
                do {
                    let locator = try await self.locator(form, url: url, whiteboard: whiteboard)
                    let arguments = try await arguments(for: candidate, locator: locator)
                    let result = try await mcp.callTool(name: candidate.tool, arguments: arguments)
                    if result.isError {
                        logFailure(tool: candidate.tool, text: result.text)
                        failure = Self.isAccessDenied(result.text)
                            ? MCPError.accessDenied(result.text)
                            : MCPError.toolFailed(result.text)
                        continue
                    }
                    if let reason = Self.resolutionFailure(in: result.text) {
                        logFailure(tool: candidate.tool, text: reason)
                        failure = MCPError.toolFailed(reason)
                        continue
                    }
                    binding = candidate
                    locatorForm = form
                    logger.debug("""
                        rovo whiteboard id=\(whiteboard.id, privacy: .public) \
                        tool=\(candidate.tool, privacy: .public) \
                        bytes=\(result.text.utf8.count, privacy: .public)
                        """)
                    return result.text
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logFailure(tool: candidate.tool, text: String(describing: error))
                    failure = error
                }
            }
        }
        let error = failure ?? MCPError.noUsableTool
        if let mcp = error as? MCPError, case .accessDenied = mcp { unsupported = mcp }
        throw error
    }

    /// `getTeamworkGraphObject` reports an unresolvable locator as HTTP 200 with
    /// an empty `objects` list plus an `errors` entry, so success cannot be
    /// judged from `isError` alone. Returns the reason, or `nil` when the payload
    /// is usable (or is not of that shape).
    static func resolutionFailure(in text: String) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let data = root.objectValue?["data"]?.objectValue,
              let objects = data["data"]?.objectValue?["objects"]?.arrayValue,
              objects.isEmpty
        else { return nil }
        let errors = (data["errors"]?.arrayValue ?? []).compactMap(\.stringValue)
        return errors.first ?? "the tool resolved no objects"
    }

    /// The MCP server reports authorization problems in the tool payload rather
    /// than as an HTTP status, so they have to be recognised by message.
    static func isAccessDenied(_ text: String) -> Bool {
        let haystack = text.lowercased()
        return haystack.contains("permission")
            || haystack.contains("unauthorized")
            || haystack.contains("forbidden")
            || haystack.contains("not authorized")
    }

    private func arguments(for binding: Binding, locator: String) async throws -> [String: JSONValue] {
        switch binding {
        case .graphObject:
            return [
                "cloudId": .string(try await cloudID()),
                "objects": .array([.string(locator)]),
            ]
        case .graphContext:
            return [
                "cloudId": .string(try await cloudID()),
                "objectIdentifier": .string(locator),
                "objectType": .string("ConfluenceWhiteboard"),
                "detailLevel": .string("full"),
            ]
        case .locator(_, let parameter, let wrapsInArray):
            return [parameter: wrapsInArray ? .array([.string(locator)]) : .string(locator)]
        }
    }

    /// Pinned form first, then the remaining ones, so a board that stops
    /// resolving by URL recovers without a remount.
    private func orderedLocatorForms(for binding: Binding) -> [LocatorForm] {
        switch binding {
        case .locator:
            return [.webURL]
        case .graphObject, .graphContext:
            let all: [LocatorForm] = [.webURL, .ari]
            guard let locatorForm else { return all }
            return [locatorForm] + all.filter { $0 != locatorForm }
        }
    }

    private func locator(_ form: LocatorForm, url: String,
                         whiteboard: ConfluenceWhiteboard) async throws -> String {
        switch form {
        case .webURL: return url
        case .ari: return "ari:cloud:confluence:\(try await cloudID()):whiteboard/\(whiteboard.id)"
        }
    }

    /// Server-generated diagnostics for a beta tool; logged public (and chunked,
    /// since os_log truncates) because it is the only way to learn the contract.
    private func logFailure(tool: String, text: String) {
        for (index, chunk) in Self.chunks(of: text).enumerated() {
            logger.error("""
                rovo whiteboard tool=\(tool, privacy: .public) \
                failed[\(index, privacy: .public)]=\(chunk, privacy: .public)
                """)
        }
    }

    /// Tenant identifier required by the Teamwork Graph tools, from the site's
    /// unauthenticated `_edge/tenant_info` endpoint.
    private func cloudID() async throws -> String {
        if let cachedCloudID { return cachedCloudID }
        guard let url = URL(string: "/_edge/tenant_info", relativeTo: siteBaseURL) else {
            throw AtlassianError.invalidURL
        }
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        guard response.statusCode == 200 else {
            throw AtlassianError.transport("tenant_info returned \(response.statusCode)")
        }
        struct TenantInfo: Decodable { let cloudId: String }
        let identifier = try JSONDecoder().decode(TenantInfo.self, from: data).cloudId
        cachedCloudID = identifier
        return identifier
    }

    private func resolveBindings() async throws -> [Binding] {
        if let unsupported { throw unsupported }
        if let candidates {
            guard let binding else { return candidates }
            return [binding] + candidates.filter { $0 != binding }
        }
        let task = discovery ?? Task { try await self.discoverBindings() }
        discovery = task
        do {
            let resolved = try await task.value
            discovery = nil
            candidates = resolved
            return resolved
        } catch {
            discovery = nil
            if let mcp = error as? MCPError, case .noUsableTool = mcp { unsupported = mcp }
            throw error
        }
    }

    private func discoverBindings() async throws -> [Binding] {
        let tools = try await mcp.listTools()
        let ordered = Self.candidateTools.compactMap { name in tools.first { $0.name == name } }
            + tools.filter { Self.mentionsWhiteboard($0) && !Self.candidateTools.contains($0.name) }
        for tool in ordered { logSchema(of: tool) }
        let resolved = ordered.compactMap(Self.binding(for:))
        if !resolved.isEmpty {
            let names = resolved.map { String(describing: $0) }.joined(separator: " ")
            logger.info("rovo whiteboard bound \(names, privacy: .public)")
            return resolved
        }
        logger.error("""
            rovo whiteboard: no usable tool among \
            \(Self.candidateTools.joined(separator: ","), privacy: .public); \
            server offers \(tools.map(\.name).sorted().joined(separator: ","), privacy: .public)
            """)
        throw MCPError.noUsableTool
    }

    static func binding(for tool: MCPClient.Tool) -> Binding? {
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        if tool.name == "getTeamworkGraphObject", properties["objects"] != nil {
            return .graphObject(tool: tool.name)
        }
        if tool.name == "getTeamworkGraphContext", properties["objectIdentifier"] != nil {
            return .graphContext(tool: tool.name)
        }
        guard let parameter = locatorParameter(of: tool.inputSchema) else { return nil }
        return .locator(tool: tool.name, parameter: parameter.name, wrapsInArray: parameter.isArray)
    }

    /// os_log truncates long strings, so the schema is emitted in chunks.
    private func logSchema(of tool: MCPClient.Tool) {
        for (index, chunk) in Self.chunks(of: Self.schemaJSON(of: tool.inputSchema)).enumerated() {
            logger.info("""
                rovo whiteboard schema \(tool.name, privacy: .public)\
                [\(index, privacy: .public)]=\(chunk, privacy: .public)
                """)
        }
    }

    static func chunks(of text: String, size: Int = 700) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [""] }
        return stride(from: 0, to: characters.count, by: size).map { start in
            String(characters[start..<min(start + size, characters.count)])
        }
    }

    static func schemaJSON(of schema: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(schema),
              let text = String(data: data, encoding: .utf8)
        else { return "<unencodable>" }
        return text
    }

    /// Fallback for renamed beta tools: anything that advertises whiteboards.
    static func mentionsWhiteboard(_ tool: MCPClient.Tool) -> Bool {
        let haystack = (tool.name + " " + (tool.description ?? "")).lowercased()
        return haystack.contains("whiteboard")
    }

    /// `name:type` list with `*` marking required properties, for diagnostics.
    static func propertySummary(of schema: JSONValue) -> String {
        guard let object = schema.objectValue,
              let properties = object["properties"]?.objectValue
        else { return "<none>" }
        let required = Set((object["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        return properties.keys.sorted().map { name in
            let type = properties[name]?.objectValue?["type"]?.stringValue ?? "?"
            return "\(name):\(type)\(required.contains(name) ? "*" : "")"
        }.joined(separator: ",")
    }

    /// Picks the input property that accepts an object locator (URL / ARI / id),
    /// preferring URL-like names and required properties. Returns whether it
    /// expects an array.
    static func locatorParameter(of schema: JSONValue) -> (name: String, isArray: Bool)? {
        guard let object = schema.objectValue,
              let properties = object["properties"]?.objectValue
        else { return nil }
        let required = Set((object["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        let ranked = properties.keys
            .compactMap { name -> (name: String, kind: Int, requirement: Int)? in
                guard let kind = Self.locatorKind(of: name) else { return nil }
                return (name, kind, required.contains(name) ? 0 : 1)
            }
            .sorted { ($0.kind, $0.requirement, $0.name) < ($1.kind, $1.requirement, $1.name) }
        guard let best = ranked.first else { return nil }
        let property = properties[best.name]?.objectValue
        let isArray = property?["type"]?.stringValue == "array" || property?["items"] != nil
        return (best.name, isArray)
    }

    /// Identifiers that address the tenant or the caller rather than the object.
    private static let contextIdentifiers: Set<String> = [
        "cloudid", "siteid", "tenantid", "orgid", "organizationid",
        "accountid", "userid", "workspaceid", "clientid",
    ]

    /// 0 for URL-ish names, 1 for a bare `id`, 2 for other id-ish names, nil when
    /// the name cannot hold an object locator.
    private static func locatorKind(of name: String) -> Int? {
        let lower = name.lowercased()
        guard !contextIdentifiers.contains(lower) else { return nil }
        if ["url", "uri", "ari"].contains(where: { lower.contains($0) }) { return 0 }
        if lower == "id" || lower == "ids" { return 1 }
        if lower.hasSuffix("id") || lower.hasSuffix("ids") { return 2 }
        return nil
    }

    /// Confluence returns `_links.webui` relative to the site's `/wiki` context;
    /// Rovo needs an absolute URL.
    func absoluteWebURL(_ webURL: String?) -> String? {
        guard let webURL, !webURL.isEmpty else { return nil }
        if let absolute = URL(string: webURL), absolute.scheme != nil {
            return absolute.absoluteString
        }
        let rooted = webURL.hasPrefix("/") ? webURL : "/" + webURL
        let path = rooted.hasPrefix("/wiki/") ? rooted : "/wiki" + rooted
        return URL(string: path, relativeTo: siteBaseURL)?.absoluteURL.absoluteString
    }
}
