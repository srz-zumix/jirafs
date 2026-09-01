import XCTest
import AtlassianCore
@testable import ConfluenceAPI

final class RovoDatabaseSourceTests: XCTestCase {
    private let database = ConfluenceDatabase(id: "d1", title: "Ideas", spaceId: "100", version: 3)

    private func source(_ stub: MCPStubTransport) -> RovoDatabaseSource {
        let mcp = MCPClient(endpoint: URL(string: "https://mcp.example.com/v2/mcp")!,
                            auth: APITokenAuth(email: "user@example.com", token: "secret"),
                            transport: stub)
        return RovoDatabaseSource(mcp: mcp, siteBaseURL: URL(string: "https://example.atlassian.net")!,
                                  transport: stub)
    }

    /// The envelope Rovo MCP v2 returns for `content_format: "csv"`.
    private static func envelope(csv: String) -> String {
        json(["data": ["id": "d1", "type": "database", "title": "Ideas",
                       "body": ["format": "csv", "value": csv]]])
    }

    /// A `tools/call` reply whose single text block is `text`.
    private static func toolReply(_ text: String, isError: Bool = false) -> MCPStubTransport.Reply {
        MCPStubTransport.json(json([
            "jsonrpc": "2.0", "id": 2,
            "result": ["isError": isError, "content": [["type": "text", "text": text]]],
        ]))
    }

    private static func json(_ object: Any) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private static let tenantInfo =
        MCPStubTransport.json(#"{"cloudId":"11111111-2222-3333-4444-555555555555"}"#)

    func testContentSendsCSVArgumentsAndReturnsEnvelope() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            Self.tenantInfo,
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            Self.toolReply(Self.envelope(csv: "_id,name\r\n1,alpha\r\n")),
        ]
        let text = try await source(stub).content(for: database)

        XCTAssertEqual(RovoDatabaseSource.csvBody(in: text), "_id,name\r\n1,alpha\r\n")
        let arguments = stub.arguments(ofRequestAt: 3)
        XCTAssertEqual(arguments?["content_id"] as? String, "d1")
        XCTAssertEqual(arguments?["content_format"] as? String, "csv")
        XCTAssertEqual(arguments?["include_metadata"] as? Bool, true)
        XCTAssertEqual(arguments?["cloudId"] as? String, "11111111-2222-3333-4444-555555555555")
    }

    func testResponseWithoutBodyIsRejected() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            Self.tenantInfo,
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            Self.toolReply(#"{"data":{}}"#),
        ]
        do {
            _ = try await source(stub).content(for: database)
            XCTFail("expected toolFailed")
        } catch MCPError.toolFailed {
            // expected
        }
    }

    /// A missing scope is mount-wide, so the source must disable itself instead
    /// of re-issuing the (billable) call for the next sibling file.
    func testInsufficientScopeIsStickyAccessDenial() async throws {
        let stub = MCPStubTransport()
        stub.replies = [
            Self.tenantInfo,
            MCPStubTransport.initializeReply,
            MCPStubTransport.initializedAck,
            Self.toolReply(Self.json([
                "error": true,
                "message": "Insufficient scopes for \"getConfluenceContent\". "
                    + "Required: [read:confluence:agent-interface].",
            ]), isError: true),
        ]
        let source = source(stub)
        for _ in 0..<2 {
            do {
                _ = try await source.content(for: database)
                XCTFail("expected accessDenied")
            } catch MCPError.accessDenied {
                // The second iteration must short-circuit on `unsupported`: no
                // further replies are queued, so reaching the stub would throw
                // `AtlassianError.transport` instead.
            }
        }
    }

    func testMountWideRejectionsAreRecognised() {
        XCTAssertTrue(RovoDatabaseSource.isMountWideRejection(
            "Insufficient scopes for \"getConfluenceContent\". Required: [read:confluence:agent-interface]."))
        XCTAssertTrue(RovoDatabaseSource.isMountWideRejection(
            "You don't have permission to connect via API token."))
        XCTAssertFalse(RovoDatabaseSource.isMountWideRejection("Database not found"))
    }

    func testCSVBodyExtraction() {
        XCTAssertEqual(RovoDatabaseSource.csvBody(in: Self.envelope(csv: "a,b\r\n1,2\r\n")),
                       "a,b\r\n1,2\r\n")
        XCTAssertNil(RovoDatabaseSource.csvBody(in: "not json"))
        XCTAssertNil(RovoDatabaseSource.csvBody(in: #"{"data":{"body":{"format":"csv"}}}"#))
    }
}
