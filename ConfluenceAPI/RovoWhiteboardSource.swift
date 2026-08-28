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
        /// Any other tool that takes the object locator in a single parameter.
        /// `form` is inferred from the parameter name so an `ari`- or `id`-named
        /// property receives the matching locator instead of always a web URL.
        case locator(tool: String, parameter: String, wrapsInArray: Bool, form: LocatorForm)

        var tool: String {
            switch self {
            case .graphObject(let tool), .graphContext(let tool), .locator(let tool, _, _, _): return tool
            }
        }
    }

    /// How the whiteboard is addressed in the tool arguments. The Teamwork Graph
    /// tools accept the web URL or ARI form (which resolves varies per board);
    /// single-parameter tools additionally may want the bare whiteboard ID.
    enum LocatorForm: Sendable, Equatable {
        case webURL
        case ari
        case rawID
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
    private var cloudIDTask: Task<String, Error>?
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
        // The tenant lookup and (server-side) board fetch derive from
        // `siteBaseURL`; refuse an insecure or user-info site URL before doing any
        // resolution, mirroring the REST client's HTTPS enforcement.
        guard siteBaseURL.scheme?.lowercased() == "https",
              siteBaseURL.user == nil, siteBaseURL.password == nil else {
            throw AtlassianError.invalidURL
        }
        // `webURL` is optional (nested boards may have no `_links.webui`); do not
        // fail the whole read when it is absent — the ARI / raw-ID forms still
        // resolve. `orderedLocatorForms` drops `.webURL` when `url` is nil.
        let url = absoluteWebURL(whiteboard.webURL)
        var failure: Error?
        /// Payload-level access denial that is specific to this board (broad
        /// "permission"/"forbidden" text): terminal for this read, higher priority
        /// than an ordinary tool failure, but not mount-wide sticky.
        var softDenial: MCPError?
        let bindings: [Binding]
        do {
            bindings = try await resolveBindings()
        } catch {
            // A handshake / `tools/list` authorization failure (HTTP 401/403,
            // surfaced by `MCPClient` as `AtlassianError`) escapes here before any
            // candidate is tried; make it sticky too so a denied mount stops
            // re-running discovery on every read.
            throw stick(error)
        }
        for candidate in bindings {
            for form in orderedLocatorForms(for: candidate, hasURL: url != nil) {
                do {
                    let locator = try await self.locator(form, url: url, whiteboard: whiteboard)
                    let arguments = try await arguments(for: candidate, locator: locator)
                    let result = try await mcp.callTool(name: candidate.tool, arguments: arguments)
                    if result.isError {
                        logFailure(tool: candidate.tool, text: result.text)
                        if Self.isScopedTokenRejection(result.text) || Self.isConnectViaTokenDenied(result.text) {
                            // An unmistakable mount-wide rejection: stop probing the
                            // remaining tools/forms immediately (each further call is
                            // billable and equally doomed) and disable the source.
                            throw stick(MCPError.accessDenied(result.text))
                        } else if Self.isAccessDenied(result.text) {
                            softDenial = softDenial ?? .accessDenied(result.text)
                        } else {
                            failure = MCPError.toolFailed(result.text)
                        }
                        continue
                    }
                    if let reason = Self.resolutionFailure(in: result.text) {
                        logFailure(tool: candidate.tool, text: reason)
                        failure = MCPError.toolFailed(reason)
                        continue
                    }
                    // A `tools/call` that "succeeds" with no text blocks yields an
                    // empty canvas. Accepting it would pin this binding and cache
                    // an empty file, blocking the fallback tools; treat it as a
                    // candidate-local failure and keep trying.
                    if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        logFailure(tool: candidate.tool, text: "empty result")
                        failure = MCPError.toolFailed("the tool returned an empty result")
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
                    // A thrown transport / HTTP-status / tenant-info / decoding
                    // error (including 429 and 5xx) is not candidate-specific:
                    // retrying every other tool and form only amplifies the
                    // site-wide Rovo rate limit and delays the eventual error.
                    // Abort this read (making genuine auth failures sticky).
                    logFailure(tool: candidate.tool, text: String(describing: error))
                    throw stick(error)
                }
            }
        }
        // Only candidate-local outcomes (tool `isError` / resolution failures)
        // reach here. Recognised mount-wide rejections already threw above via
        // `stick`, so surface the board-specific denial (preferred over a plain
        // tool failure) or the last ordinary failure.
        throw softDenial ?? failure ?? MCPError.noUsableTool
    }

    /// Pins a terminal authorization failure so subsequent reads short-circuit
    /// via `unsupported` instead of repeating discovery / tool calls. Only
    /// permanent auth failures (MCP `accessDenied`, HTTP 401/403) are made sticky;
    /// transient errors (429, 5xx, transport) and ordinary `toolFailed` are not.
    private func stick(_ error: Error) -> Error {
        let sticky: MCPError?
        if let mcp = error as? MCPError, case .accessDenied = mcp {
            sticky = mcp
        } else if let atl = error as? AtlassianError {
            switch atl {
            case .forbidden: sticky = .accessDenied("forbidden")
            case .unauthorized: sticky = .accessDenied("unauthorized")
            default: sticky = nil
            }
        } else {
            sticky = nil
        }
        if let sticky {
            unsupported = sticky
            return sticky
        }
        return error
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

    /// The documented, unmistakable global rejection ("Teamwork Graph tools
    /// require a modern API token (API token with scopes)."). Unlike a broad
    /// per-object "permission" message this can never resolve for the mount's
    /// credential, so it disables the whole source rather than just this read.
    static func isScopedTokenRejection(_ text: String) -> Bool {
        let haystack = text.lowercased()
        return haystack.contains("modern api token") && haystack.contains("scope")
    }

    /// The org-level rejection surfaced when an API token is not permitted to
    /// connect at all ("You don't have permission to connect via API token.").
    /// This is mount-wide like a scoped-token rejection, so match the whole known
    /// phrase — not its individual words — to avoid classifying a board-specific
    /// "permission" message as a global denial.
    static func isConnectViaTokenDenied(_ text: String) -> Bool {
        text.lowercased().contains("permission to connect via api token")
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
        case .locator(_, let parameter, let wrapsInArray, _):
            return [parameter: wrapsInArray ? .array([.string(locator)]) : .string(locator)]
        }
    }

    /// Pinned form first, then the remaining ones, so a board that stops
    /// resolving by URL recovers without a remount. `hasURL` drops `.webURL` when
    /// the board has no web link, leaving the ARI / raw-ID forms.
    private func orderedLocatorForms(for binding: Binding, hasURL: Bool) -> [LocatorForm] {
        switch binding {
        case .locator(_, _, _, let form):
            // A single-parameter tool expects exactly one locator shape (derived
            // from its property name); putting a URL in an `ari`/`id` property
            // just produces a spurious failure, so do not fan out over forms.
            return form == .webURL && !hasURL ? [] : [form]
        case .graphObject, .graphContext:
            let all: [LocatorForm] = hasURL ? [.webURL, .ari] : [.ari]
            guard let locatorForm, all.contains(locatorForm) else { return all }
            return [locatorForm] + all.filter { $0 != locatorForm }
        }
    }

    private func locator(_ form: LocatorForm, url: String?,
                         whiteboard: ConfluenceWhiteboard) async throws -> String {
        switch form {
        case .webURL:
            guard let url else { throw AtlassianError.notFound }
            return url
        case .ari: return "ari:cloud:confluence:\(try await cloudID()):whiteboard/\(whiteboard.id)"
        case .rawID: return whiteboard.id
        }
    }

    /// Server-generated diagnostics for a beta tool. The text can echo the
    /// whiteboard payload or user-authored content, so it is logged `.private`
    /// (only the tool name and chunk index stay public); chunking works around
    /// os_log truncation.
    private func logFailure(tool: String, text: String) {
        for (index, chunk) in Self.chunks(of: text).enumerated() {
            logger.error("""
                rovo whiteboard tool=\(tool, privacy: .public) \
                failed[\(index, privacy: .public)]=\(chunk, privacy: .private)
                """)
        }
    }

    /// Tenant identifier required by the Teamwork Graph tools, from the site's
    /// unauthenticated `_edge/tenant_info` endpoint. Single-flighted so a fan-out
    /// of board reads issues one lookup instead of one per read.
    private func cloudID() async throws -> String {
        if let cachedCloudID { return cachedCloudID }
        if let cloudIDTask { return try await cloudIDTask.value }
        let task = Task { try await self.fetchCloudID() }
        cloudIDTask = task
        do {
            let identifier = try await task.value
            cloudIDTask = nil
            cachedCloudID = identifier
            return identifier
        } catch {
            cloudIDTask = nil
            throw error
        }
    }

    private func fetchCloudID() async throws -> String {
        guard let url = URL(string: "/_edge/tenant_info", relativeTo: siteBaseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil else {
            throw AtlassianError.invalidURL
        }
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        guard response.statusCode == 200 else {
            throw Self.mapStatus(response.statusCode, context: "tenant_info")
        }
        struct TenantInfo: Decodable { let cloudId: String }
        let identifier = try JSONDecoder().decode(TenantInfo.self, from: data).cloudId
        // The ID is interpolated into an ARI / tool arguments; `tenant_info` is
        // unauthenticated, so reject anything but the opaque UUID-style form to
        // keep a tampered response from injecting delimiters.
        guard ConfluenceRESTClient.isValidCloudID(identifier) else {
            throw AtlassianError.decoding("tenant_info returned a malformed cloudId")
        }
        return identifier
    }

    /// Maps an HTTP status to an `AtlassianError` so `stick(_:)` can decide
    /// stickiness (401/403 terminal; 429/5xx transient).
    private static func mapStatus(_ status: Int, context: String) -> AtlassianError {
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        default: return .transport("\(context) returned \(status)")
        }
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
        // The `.locator` fallback only fills the single locator parameter. If the
        // schema marks any *other* field as required, the advertised call is
        // guaranteed to fail server-side validation, so skip the tool rather than
        // issue a doomed (rate-limited, billable) request.
        let required = Set((tool.inputSchema.objectValue?["required"]?.arrayValue ?? [])
            .compactMap(\.stringValue))
        guard required.subtracting([parameter.name]).isEmpty else { return nil }
        return .locator(tool: tool.name, parameter: parameter.name,
                        wrapsInArray: parameter.isArray, form: locatorForm(for: parameter.name))
    }

    /// Chooses the locator shape a single-parameter tool wants from its property
    /// name: an `ari`-named property gets an ARI, a `url`/`uri` one the web URL,
    /// and a bare `id`/`*Id` one the raw whiteboard ID.
    static func locatorForm(for parameter: String) -> LocatorForm {
        let lower = parameter.lowercased()
        if lower.contains("ari") { return .ari }
        if lower.contains("url") || lower.contains("uri") { return .webURL }
        return .rawID
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
            // Requirement first: the `.locator` binding can fill exactly one
            // parameter, so a *required* locator field must win over an optional
            // one — otherwise `binding(for:)` would pick the optional field and
            // then reject the tool because the required field stays unfilled.
            // Within the same requirement tier, prefer the more locator-like kind.
            .sorted { ($0.requirement, $0.kind, $0.name) < ($1.requirement, $1.kind, $1.name) }
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

    /// Identifiers that address a *related* object (the board's parent/container)
    /// rather than the board itself. Filling one of these with the whiteboard's
    /// locator would address the wrong object, so — like tenant identifiers — they
    /// are never eligible to carry the locator even when marked required.
    private static let relationshipIdentifiers: Set<String> = [
        "parentid", "parentids", "containerid", "containerids",
        "ancestorid", "ancestorids", "spaceid", "folderid",
    ]

    /// 0 for URL-ish names, 1 for a bare `id`, 2 for other id-ish names, nil when
    /// the name cannot hold an object locator.
    private static func locatorKind(of name: String) -> Int? {
        let lower = name.lowercased()
        guard !contextIdentifiers.contains(lower), !relationshipIdentifiers.contains(lower) else { return nil }
        if ["url", "uri", "ari"].contains(where: { lower.contains($0) }) { return 0 }
        if lower == "id" || lower == "ids" { return 1 }
        if lower.hasSuffix("id") || lower.hasSuffix("ids") { return 2 }
        return nil
    }

    /// Confluence returns `_links.webui` relative to the site's `/wiki` context;
    /// Rovo needs an absolute URL. An already-absolute `webui` is only honoured
    /// when it is HTTPS and same-origin with `siteBaseURL`: the resolved URL is
    /// handed to an authenticated Rovo tool, so an attacker-influenced `_links`
    /// value pointing at an arbitrary scheme/host must not be forwarded. A
    /// rejected absolute URL returns nil so the caller falls back to the ARI /
    /// raw-ID forms.
    func absoluteWebURL(_ webURL: String?) -> String? {
        guard let webURL, !webURL.isEmpty else { return nil }
        if let absolute = URL(string: webURL), absolute.scheme != nil {
            guard absolute.scheme?.lowercased() == "https",
                  let sameOrigin = InstanceURLValidator.sameOriginURL(webURL, base: siteBaseURL)
            else { return nil }
            return sameOrigin.absoluteString
        }
        let rooted = webURL.hasPrefix("/") ? webURL : "/" + webURL
        let path = rooted.hasPrefix("/wiki/") ? rooted : "/wiki" + rooted
        return URL(string: path, relativeTo: siteBaseURL)?.absoluteURL.absoluteString
    }
}
