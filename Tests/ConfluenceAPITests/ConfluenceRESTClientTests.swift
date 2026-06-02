import XCTest
import AtlassianCore
@testable import ConfluenceAPI

/// In-memory transport stub used by `ConfluenceRESTClient` tests.
final class ConfluenceStubTransport: HTTPTransport, @unchecked Sendable {
    var responses: [String: (Int, Data)] = [:]
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let key = request.url?.absoluteString ?? ""
        let pair = responses.first { key.contains($0.key) }?.value ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: pair.0, httpVersion: nil, headerFields: nil)!
        return (pair.1, response)
    }
}

final class ConfluenceRESTClientTests: XCTestCase {
    private func cloudClient(_ stub: ConfluenceStubTransport) -> ConfluenceRESTClient {
        let cfg = ConfluenceInstanceConfig(
            name: "cloud",
            baseURL: URL(string: "https://example.atlassian.net")!,
            edition: .cloud
        )
        return ConfluenceRESTClient(config: cfg, auth: APITokenAuth(email: "x", token: "y"), transport: stub)
    }

    private func dcClient(_ stub: ConfluenceStubTransport) -> ConfluenceRESTClient {
        let cfg = ConfluenceInstanceConfig(
            name: "dc",
            baseURL: URL(string: "https://wiki.example.com")!,
            edition: .dataCenter
        )
        return ConfluenceRESTClient(config: cfg, auth: PATAuth(token: "tok"), transport: stub)
    }

    func testCloudListSpacesCursor() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [{"id":"100","key":"DOC","name":"Docs","type":"global"}],
          "_links": {"next": "/wiki/api/v2/spaces?cursor=NEXTTOKEN&limit=25"}
        }
        """
        stub.responses["/wiki/api/v2/spaces"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let page = try await client.listSpaces(cursor: nil, limit: 25)
        XCTAssertEqual(page.items.first?.key, "DOC")
        XCTAssertEqual(page.items.first?.id, "100")
        XCTAssertEqual(page.nextCursor, "NEXTTOKEN")
        XCTAssertTrue(stub.requests.first?.url?.absoluteString.contains("/wiki/api/v2/spaces") ?? false)
    }

    func testCloudGetPageStorageBody() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "id": "555",
          "title": "Hello",
          "spaceId": "100",
          "parentId": "1",
          "version": {"number": 3},
          "body": {"storage": {"value": "<p>hi</p>", "representation": "storage"}},
          "_links": {"webui": "/spaces/DOC/pages/555"}
        }
        """
        stub.responses["/wiki/api/v2/pages/555"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let page = try await client.getPage(id: "555", bodyFormat: .storage)
        XCTAssertEqual(page.title, "Hello")
        XCTAssertEqual(page.parentId, "1")
        XCTAssertEqual(page.version, 3)
        XCTAssertEqual(page.body?.format, .storage)
        XCTAssertEqual(page.body?.value, "<p>hi</p>")
    }

    func testDCListSpacesStartLimitPagination() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [{"id": 98306, "key": "TEAM", "name": "Team", "type": "global"}],
          "start": 0, "limit": 1, "size": 1,
          "_links": {"next": "/rest/api/space?start=1&limit=1"}
        }
        """
        stub.responses["/rest/api/space"] = (200, Data(json.utf8))
        let client = dcClient(stub)
        let page = try await client.listSpaces(cursor: nil, limit: 1)
        XCTAssertEqual(page.items.first?.key, "TEAM")
        XCTAssertEqual(page.items.first?.id, "98306")
        XCTAssertEqual(page.nextCursor, "1") // next start offset
    }

    func testCloudRootPagesUsesV2DepthRoot() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [{"id": "200", "title": "Root Page",
                       "spaceId": "100", "parentId": null,
                       "version": {"number": 1, "createdAt": "2024-01-01T00:00:00Z"},
                       "_links": {"webui": "/spaces/DOC/pages/200"}}],
          "_links": {}
        }
        """
        stub.responses["/wiki/api/v2/spaces/100/pages"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let space = ConfluenceSpace(id: "100", key: "DOC", name: "Docs")
        let page = try await client.listRootPages(space: space, cursor: nil, limit: 25)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.title, "Root Page")
        XCTAssertNil(page.nextCursor)
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/wiki/api/v2/spaces/100/pages"), "URL was \(url)")
        XCTAssertTrue(url.contains("depth=root"), "URL was \(url)")
        XCTAssertTrue(url.contains("status=current"), "URL was \(url)")
    }

    func testDCRootPagesUsesDepthRoot() async throws {        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [{"id": "777", "title": "Root", "space": {"id": 1, "key": "TEAM"},
                       "body": {"storage": {"value": "<p>x</p>", "representation": "storage"}}}],
          "start": 0, "limit": 25, "size": 1, "_links": {}
        }
        """
        stub.responses["/rest/api/space/TEAM/content/page"] = (200, Data(json.utf8))
        let client = dcClient(stub)
        let space = ConfluenceSpace(id: "98306", key: "TEAM", name: "Team")
        let page = try await client.listRootPages(space: space, cursor: nil, limit: 25)
        XCTAssertEqual(page.items.first?.title, "Root")
        XCTAssertNil(page.nextCursor) // no next link and size < limit
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("depth=root"), "URL was \(url)")
        XCTAssertTrue(url.contains("status=current"), "URL was \(url)")
    }

    func testCloudArchivedRootPagesUsesStatusArchived() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [{"id": "300", "title": "Old Page",
                       "spaceId": "100", "parentId": null,
                       "version": {"number": 2, "createdAt": "2023-01-01T00:00:00Z"},
                       "_links": {"webui": "/spaces/DOC/pages/300"}}],
          "_links": {}
        }
        """
        stub.responses["/wiki/api/v2/spaces/100/pages"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let space = ConfluenceSpace(id: "100", key: "DOC", name: "Docs")
        let page = try await client.listArchivedRootPages(space: space, cursor: nil, limit: 25)
        XCTAssertEqual(page.items.first?.title, "Old Page")
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("depth=root"), "URL was \(url)")
        XCTAssertTrue(url.contains("status=archived"), "URL was \(url)")
    }

    func testDCGetPageStorageBody() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "id": "777",
          "title": "Page",
          "space": {"id": 1, "key": "TEAM"},
          "ancestors": [{"id": "1"}, {"id": "2"}],
          "version": {"number": 4, "by": {"displayName": "Alice"}, "when": "2024-01-01T00:00:00Z"},
          "body": {"storage": {"value": "<h1>Title</h1>", "representation": "storage"}}
        }
        """
        stub.responses["/rest/api/content/777"] = (200, Data(json.utf8))
        let client = dcClient(stub)
        let page = try await client.getPage(id: "777", bodyFormat: .storage)
        XCTAssertEqual(page.parentId, "2") // last ancestor is the direct parent
        XCTAssertEqual(page.version, 4)
        XCTAssertEqual(page.authorId, "Alice")
        XCTAssertEqual(page.body?.value, "<h1>Title</h1>")
    }

    func testNotFoundMaps() async throws {
        let stub = ConfluenceStubTransport()
        let client = cloudClient(stub)
        do {
            _ = try await client.getPage(id: "MISSING", bodyFormat: .storage)
            XCTFail("expected error")
        } catch let error as AtlassianError {
            XCTAssertEqual(error, .notFound)
        }
    }
}
