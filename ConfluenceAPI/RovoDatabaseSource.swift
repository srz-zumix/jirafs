import Foundation
import AtlassianCore

/// Fetches Confluence database rows through the Atlassian Rovo MCP server.
///
/// The Confluence REST API exposes only database *metadata* — there is no
/// endpoint returning rows or field definitions (`databases/{id}/entries` is
/// 404, and the v1 `body.storage` of a database is an empty string). The Rovo
/// MCP v2 `getConfluenceContent` tool documents `csv` as the database
/// representation and is the only known way to read the data.
///
/// Unlike the beta Teamwork Graph tools driven by `RovoWhiteboardSource`, this
/// tool has a stable documented signature, so it is invoked directly instead of
/// being discovered from `tools/list`. Cloud only.
public actor RovoDatabaseSource {
    /// Atlassian's hosted MCP endpoint. Databases are only served by v2; the v1
    /// server used for whiteboards does not expose `getConfluenceContent`.
    public static let defaultEndpoint = URL(string: "https://mcp.atlassian.com/v2/mcp")!

    static let toolName = "getConfluenceContent"

    private let mcp: MCPClient
    private let siteBaseURL: URL
    private let transport: HTTPTransport
    private var cachedCloudID: String?
    private var cloudIDTask: Task<String, Error>?
    /// Set once the server is known to reject this mount's credential, so the
    /// file system stops re-issuing (rate-limited, billable) calls.
    private var unsupported: MCPError?
    private let logger = AtlassianLog.logger("rovo-database")

    public init(mcp: MCPClient, siteBaseURL: URL, transport: HTTPTransport = URLSessionTransport()) {
        self.mcp = mcp
        self.siteBaseURL = siteBaseURL
        self.transport = transport
    }

    /// The verbatim MCP response for the database, whose `data.body.value` holds
    /// the CSV rendering. Throws when Rovo refuses or cannot resolve it.
    public func content(for database: ConfluenceDatabase) async throws -> String {
        guard siteBaseURL.scheme?.lowercased() == "https",
              siteBaseURL.user == nil, siteBaseURL.password == nil else {
            throw AtlassianError.invalidURL
        }
        if let unsupported { throw unsupported }
        let arguments: [String: JSONValue] = [
            "cloudId": .string(try await cloudID()),
            "content_id": .string(database.id),
            "content_format": .string("csv"),
            "include_metadata": .bool(true),
        ]
        let result: MCPClient.ToolResult
        do {
            result = try await mcp.callTool(name: Self.toolName, arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logFailure(String(describing: error))
            throw stick(error)
        }
        if result.isError {
            logFailure(result.text)
            if Self.isMountWideRejection(result.text) {
                throw stick(MCPError.accessDenied(result.text))
            }
            throw MCPError.toolFailed(result.text)
        }
        // A `tools/call` that "succeeds" with no CSV would cache an empty table,
        // so require the envelope to actually carry a body before accepting it.
        guard Self.csvBody(in: result.text) != nil else {
            logFailure(result.text)
            throw MCPError.toolFailed("the tool returned no database body")
        }
        logger.debug("""
            rovo database id=\(database.id, privacy: .public) \
            bytes=\(result.text.utf8.count, privacy: .public)
            """)
        return result.text
    }

    /// Extracts the CSV payload from the `getConfluenceContent` envelope
    /// (`data.body.value`). Returns `nil` when the response is not of that shape.
    public static func csvBody(in text: String) -> String? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let body = root.objectValue?["data"]?.objectValue?["body"]?.objectValue,
              let value = body["value"]?.stringValue
        else { return nil }
        return value
    }

    /// Rejections that can never resolve for this mount's credential, so the
    /// whole source is disabled rather than just this read: the organization
    /// disallowing API-token access, a classic (non-scoped) token, and a scoped
    /// token missing `read:confluence:agent-interface`.
    static func isMountWideRejection(_ text: String) -> Bool {
        let haystack = text.lowercased()
        return haystack.contains("permission to connect via api token")
            || (haystack.contains("modern api token") && haystack.contains("scope"))
            || haystack.contains("insufficient scopes")
    }

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

    /// The payload can echo user-authored row data, so it is logged `.private`;
    /// chunking works around os_log truncation.
    private func logFailure(_ text: String) {
        for (index, chunk) in RovoWhiteboardSource.chunks(of: text).enumerated() {
            logger.error("""
                rovo database tool=\(Self.toolName, privacy: .public) \
                failed[\(index, privacy: .public)]=\(chunk, privacy: .private)
                """)
        }
    }

    /// Tenant identifier required by `getConfluenceContent`, from the site's
    /// unauthenticated `_edge/tenant_info` endpoint. Single-flighted so a fan-out
    /// of database reads issues one lookup instead of one per read.
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
            switch response.statusCode {
            case 401: throw AtlassianError.unauthorized
            case 403: throw AtlassianError.forbidden
            case 404: throw AtlassianError.notFound
            default: throw AtlassianError.transport("tenant_info returned \(response.statusCode)")
            }
        }
        struct TenantInfo: Decodable { let cloudId: String }
        let identifier = try JSONDecoder().decode(TenantInfo.self, from: data).cloudId
        // The ID is passed straight to the tool; `tenant_info` is unauthenticated,
        // so reject anything but the opaque UUID-style form.
        guard ConfluenceRESTClient.isValidCloudID(identifier) else {
            throw AtlassianError.decoding("tenant_info returned a malformed cloudId")
        }
        return identifier
    }
}
