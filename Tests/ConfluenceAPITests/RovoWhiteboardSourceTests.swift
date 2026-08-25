import XCTest
import AtlassianCore
@testable import ConfluenceAPI

/// Transport stub that replays queued responses in order. MCP sends every
/// JSON-RPC message to the same endpoint, so responses cannot be keyed by URL.
final class MCPStubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    var replies: [Reply] = []
    private(set) var requests: [URLRequest] = []
    private var index = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard index < replies.count else {
            throw AtlassianError.transport("unexpected request \(requests.count)")
        }
        let reply = replies[index]
        index += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: nil, headerFields: reply.headers)!
        return (reply.body, response)
    }

    /// Method names of the JSON-RPC requests captured so far.
    var methods: [String] {
        requests.compactMap { request in
            guard let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json["method"] as? String
        }
    }

    func arguments(ofRequestAt index: Int) -> [String: Any]? {
        guard index < requests.count, let body = requests[index].httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let params = json["params"] as? [String: Any]
        else { return nil }
        return params["arguments"] as? [String: Any]
    }

    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
        var merged = headers
        merged["Content-Type"] = "application/json"
        return Reply(status: status, headers: merged, body: Data(text.utf8))
    }

    /// Wraps `text` as a single SSE `data:` event.
    static func sse(_ text: String, headers: [String: String] = [:]) -> Reply {
        var merged = headers
        merged["Content-Type"] = "text/event-stream"
        let payload = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "data: \($0)" }
            .joined(separator: "\n")
        return Reply(status: 200, headers: merged, body: Data("event: message\n\(payload)\n\n".utf8))
    }

    static let initializeReply = json("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"rovo"}}}
        """, headers: ["Mcp-Session-Id": "sess-1"])

    static let initializedAck = Reply(status: 202, headers: [:], body: Data())
}

final class MCPClientTests: XCTestCase {
    private func client(_ stub: MCPStubTransport) -> MCPClient {
        MCPClient(endpoint: URL(string: "https://mcp.example.com/v1/mcp")!,
                  auth: APITokenAuth(email: "user@example.com", token: "secret"),
                  transport: stub)
    }

    func testHandshakePrecedesToolCallAndAuthorizes() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"hello"}]}}
                """),
        ]
        let result = try await client(stub).callTool(name: "doThing", arguments: ["url": .string("https://x")])

        XCTAssertEqual(result.text, "hello")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(stub.methods, ["initialize", "notifications/initialized", "tools/call"])
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Accept"),
                       "application/json, text/event-stream")
        XCTAssertNotNil(stub.requests.first?.value(forHTTPHeaderField: "Authorization"))
        // The session id returned by `initialize` is echoed on later requests.
        XCTAssertEqual(stub.requests.last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-1")
    }

    func testDecodesSSEFramedResult() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            MCPStubTransport.sse("""
                {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}
                """),
        ]
        let result = try await client(stub).callTool(name: "doThing", arguments: [:])
        XCTAssertEqual(result.text, "a\nb")
    }

    func testListToolsParsesSchema() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":2,"result":{"tools":[
                  {"name":"getTeamworkGraphObject","description":"fetch",
                   "inputSchema":{"type":"object","properties":{"urls":{"type":"array"}},"required":["urls"]}}
                ]}}
                """),
        ]
        let tools = try await client(stub).listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "getTeamworkGraphObject")
        XCTAssertNotNil(tools.first?.inputSchema.objectValue?["properties"])
    }

    func testJSONRPCErrorSurfaces() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}
                """),
        ]
        do {
            _ = try await client(stub).listTools()
            XCTFail("expected an RPC error")
        } catch MCPError.rpc(let code, _) {
            XCTAssertEqual(code, -32601)
        }
    }

    func testUnauthorizedMapsToAtlassianError() async throws {
        let stub = MCPStubTransport()
        stub.replies = [MCPStubTransport.json("{}", status: 401)]
        do {
            _ = try await client(stub).listTools()
            XCTFail("expected unauthorized")
        } catch AtlassianError.unauthorized {
            // expected
        }
    }
}

final class RovoWhiteboardSourceTests: XCTestCase {
    private let board = ConfluenceWhiteboard(
        id: "w1", title: "Design Board", spaceId: "100",
        webURL: "/spaces/ENG/whiteboards/w1"
    )

    private func source(_ stub: MCPStubTransport) -> RovoWhiteboardSource {
        let mcp = MCPClient(endpoint: URL(string: "https://mcp.example.com/v1/mcp")!,
                            auth: APITokenAuth(email: "user@example.com", token: "secret"),
                            transport: stub)
        return RovoWhiteboardSource(mcp: mcp, siteBaseURL: URL(string: "https://example.atlassian.net")!,
                                    transport: stub)
    }

    func testLocatorParameterPrefersRequiredArrayProperty() {
        let schema = JSONValue.object([
            "properties": .object([
                "cloudId": .object(["type": .string("string")]),
                "objectUrls": .object(["type": .string("array")]),
            ]),
            "required": .array([.string("objectUrls")]),
        ])
        let parameter = RovoWhiteboardSource.locatorParameter(of: schema)
        XCTAssertEqual(parameter?.name, "objectUrls")
        XCTAssertEqual(parameter?.isArray, true)
    }

    func testLocatorParameterNilWhenNoLocatorLikeProperty() {
        let schema = JSONValue.object([
            "properties": .object(["query": .object(["type": .string("string")])]),
        ])
        XCTAssertNil(RovoWhiteboardSource.locatorParameter(of: schema))
    }

    func testLocatorParameterIgnoresTenantIdentifiers() {
        let schema = JSONValue.object([
            "properties": .object([
                "cloudId": .object(["type": .string("string")]),
                "objectId": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("cloudId"), .string("objectId")]),
        ])
        XCTAssertEqual(RovoWhiteboardSource.locatorParameter(of: schema)?.name, "objectId")
    }

    func testLocatorParameterNilWhenOnlyTenantIdentifier() {
        let schema = JSONValue.object([
            "properties": .object(["cloudId": .object(["type": .string("string")])]),
        ])
        XCTAssertNil(RovoWhiteboardSource.locatorParameter(of: schema))
    }

    func testRelativeWebURLIsResolvedAgainstWikiContext() async {
        let stub = MCPStubTransport()
        let resolved = await source(stub).absoluteWebURL("/spaces/ENG/whiteboards/w1")
        XCTAssertEqual(resolved, "https://example.atlassian.net/wiki/spaces/ENG/whiteboards/w1")
    }

    func testAbsoluteWebURLIsPassedThrough() async {
        let stub = MCPStubTransport()
        let resolved = await source(stub).absoluteWebURL("https://other.example/wiki/x")
        XCTAssertEqual(resolved, "https://other.example/wiki/x")
    }

    func testContentDiscoversToolAndSendsAbsoluteURL() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":2,"result":{"tools":[
                  {"name":"getTeamworkGraphObject",
                   "inputSchema":{"type":"object","properties":{"urls":{"type":"array"}},"required":["urls"]}}
                ]}}
                """),
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"sticky note: ship it"}]}}
                """),
        ]
        let text = try await source(stub).content(for: board)

        XCTAssertEqual(text, "sticky note: ship it")
        XCTAssertEqual(stub.methods, ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        let arguments = stub.arguments(ofRequestAt: 3)
        XCTAssertEqual(arguments?["urls"] as? [String],
                       ["https://example.atlassian.net/wiki/spaces/ENG/whiteboards/w1"])
    }

    func testContentFailsWhenNoWhiteboardCapableToolExists() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"searchJiraIssuesUsingJql","inputSchema":{}}]}}
                """),
        ]
        do {
            _ = try await source(stub).content(for: board)
            XCTFail("expected noUsableTool")
        } catch MCPError.noUsableTool {
            // expected
        }
    }

    func testToolReportedErrorIsSurfaced() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":2,"result":{"tools":[
                  {"name":"fetchAtlassian",
                   "inputSchema":{"type":"object","properties":{"ari":{"type":"string"}},"required":["ari"]}}
                ]}}
                """),
            MCPStubTransport.json(#"{"cloudId":"cloud-1"}"#),
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":3,"result":{"isError":true,"content":[{"type":"text","text":"not permitted"}]}}
                """),
        ]
        do {
            _ = try await source(stub).content(for: board)
            XCTFail("expected toolFailed")
        } catch MCPError.toolFailed(let message) {
            XCTAssertEqual(message, "not permitted")
        }
    }

    func testEmptyObjectsPayloadIsTreatedAsFailure() {
        let payload = """
            {"data":{"data":{"objects":[]},"errors":["Failed to resolve URL"]},"statusCode":200}
            """
        XCTAssertEqual(RovoWhiteboardSource.resolutionFailure(in: payload), "Failed to resolve URL")
    }

    func testEmptyObjectsWithoutErrorsStillFails() {
        let payload = #"{"data":{"data":{"objects":[]}},"statusCode":200}"#
        XCTAssertNotNil(RovoWhiteboardSource.resolutionFailure(in: payload))
    }

    func testResolvedObjectsAreAccepted() {
        let payload = #"{"data":{"data":{"objects":[{"raw":{"bodyValue":"{}"}}]}},"statusCode":200}"#
        XCTAssertNil(RovoWhiteboardSource.resolutionFailure(in: payload))
    }

    func testNonGraphObjectPayloadIsAccepted() {
        XCTAssertNil(RovoWhiteboardSource.resolutionFailure(in: "sticky note: ship it"))
    }

    func testFallsBackToARIWhenURLDoesNotResolve() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":2,"result":{"tools":[
                  {"name":"getTeamworkGraphObject",
                   "inputSchema":{"type":"object","properties":{"cloudId":{"type":"string"},\
                   "objects":{"type":"array"}},"required":["cloudId","objects"]}}
                ]}}
                """),
            MCPStubTransport.json(#"{"cloudId":"cloud-1"}"#),
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text",\
                "text":"{\\"data\\":{\\"data\\":{\\"objects\\":[]},\\"errors\\":[\\"no provider\\"]}}"}]}}
                """),
            MCPStubTransport.json("""
                {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"canvas"}]}}
                """),
        ]
        let mcp = MCPClient(endpoint: URL(string: "https://mcp.example.com/v1/mcp")!,
                            auth: APITokenAuth(email: "user@example.com", token: "secret"),
                            transport: stub)
        let source = RovoWhiteboardSource(mcp: mcp,
                                          siteBaseURL: URL(string: "https://example.atlassian.net")!,
                                          transport: stub)
        let text = try await source.content(for: board)

        XCTAssertEqual(text, "canvas")
        XCTAssertEqual(stub.arguments(ofRequestAt: 4)?["objects"] as? [String],
                       ["https://example.atlassian.net/wiki/spaces/ENG/whiteboards/w1"])
        XCTAssertEqual(stub.arguments(ofRequestAt: 5)?["objects"] as? [String],
                       ["ari:cloud:confluence:cloud-1:whiteboard/w1"])
    }
}
