import XCTest
import AtlassianCore
@testable import ConfluenceAPI

/// In-memory transport stub used by `ConfluenceRESTClient` tests.
final class ConfluenceStubTransport: HTTPTransport, @unchecked Sendable {
    var responses: [String: (Int, Data)] = [:]
    var responseHeaders: [String: [String: String]] = [:]
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let key = request.url?.absoluteString ?? ""
        let pair = responses.first { key.contains($0.key) }?.value ?? (404, Data())
        let headers = responseHeaders.first { key.contains($0.key) }?.value
        let response = HTTPURLResponse(url: request.url!, statusCode: pair.0, httpVersion: nil, headerFields: headers)!
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

    func testCloudGetPageViewBody() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "id": "555",
          "title": "Hello",
          "spaceId": "100",
          "parentId": "1",
          "version": {"number": 3},
          "body": {"view": {"value": "<h2>Rendered</h2>", "representation": "view"}},
          "_links": {"webui": "/spaces/DOC/pages/555"}
        }
        """
        stub.responses["/wiki/api/v2/pages/555"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let page = try await client.getPage(id: "555", bodyFormat: .view)
        let items = URLComponents(url: try XCTUnwrap(stub.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "body-format" }?.value, "view")
        XCTAssertEqual(page.body?.format, .view)
        XCTAssertEqual(page.body?.value, "<h2>Rendered</h2>")
    }

    func testDCGetPageViewBody() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "id": "777",
          "title": "Page",
          "space": {"id": 1, "key": "TEAM"},
          "ancestors": [{"id": "1"}],
          "version": {"number": 4, "by": {"displayName": "Alice"}, "when": "2024-01-01T00:00:00Z"},
          "body": {"view": {"value": "<h1>Rendered</h1>", "representation": "view"}}
        }
        """
        stub.responses["/rest/api/content/777"] = (200, Data(json.utf8))
        let client = dcClient(stub)
        let page = try await client.getPage(id: "777", bodyFormat: .view)
        let items = URLComponents(url: try XCTUnwrap(stub.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        let expand = try XCTUnwrap(items.first { $0.name == "expand" }?.value)
        XCTAssertTrue(expand.contains("body.view"), "expand was \(expand)")
        XCTAssertFalse(expand.contains("body.storage"), "expand was \(expand)")
        XCTAssertEqual(page.body?.format, .view)
        XCTAssertEqual(page.body?.value, "<h1>Rendered</h1>")
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

    // MARK: - Restrictions

    func testDCListRootPagesRestrictionsExpandAndMapping() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [
            {
              "id": "10", "title": "Open",
              "restrictions": {
                "read":   { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } },
                "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } }
              }
            },
            {
              "id": "20", "title": "UserRead",
              "restrictions": {
                "read":   { "restrictions": { "user": {"size": 2}, "group": {"size": 0} } },
                "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } }
              }
            },
            {
              "id": "30", "title": "GroupUpdate",
              "restrictions": {
                "read":   { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } },
                "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 1} } }
              }
            }
          ],
          "start": 0, "limit": 25, "size": 3, "_links": {}
        }
        """
        stub.responses["/rest/api/space/TEAM/content/page"] = (200, Data(json.utf8))
        let client = dcClient(stub)
        let space = ConfluenceSpace(id: "98306", key: "TEAM", name: "Team")
        let page = try await client.listRootPages(space: space, cursor: nil, limit: 25)
        XCTAssertEqual(page.items.count, 3)
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("expand="), "URL should include expand: \(url)")
        XCTAssertTrue(url.contains("restrictions.read.restrictions.user"), "URL should include read-user expand: \(url)")
        let open = page.items.first { $0.id == "10" }
        let userRestricted = page.items.first { $0.id == "20" }
        let groupRestricted = page.items.first { $0.id == "30" }
        XCTAssertEqual(open?.hasRestrictions, false)
        XCTAssertEqual(userRestricted?.hasRestrictions, true)
        XCTAssertEqual(groupRestricted?.hasRestrictions, true)
    }

    func testCloudRestrictedRootPageIDsScopedToRootOnly() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [
            {
              "id": "100",
              "restrictions": {
                "read":   { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } },
                "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } }
              }
            },
            {
              "id": "200",
              "restrictions": {
                "read":   { "restrictions": { "user": {"size": 1}, "group": {"size": 0} } },
                "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } }
              }
            },
            {
              "id": "300",
              "restrictions": {
                "read":   { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } },
                "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 2} } }
              }
            }
          ],
          "start": 0, "size": 3, "_links": {}
        }
        """
        stub.responses["/wiki/rest/api/space/DOC/content/page"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let ids = try await client.restrictedRootPageIDs(spaceKey: "DOC", status: "current", limiter: RateLimiter())
        XCTAssertFalse(ids.contains("100"), "Page 100 has no restrictions")
        XCTAssertTrue(ids.contains("200"), "Page 200 has user read restriction")
        XCTAssertTrue(ids.contains("300"), "Page 300 has group update restriction")
        XCTAssertEqual(ids.count, 2)
        let url = stub.requests.first?.url?.absoluteString ?? ""
        // Must use the scoped space content endpoint, NOT the global content search
        XCTAssertTrue(url.contains("/wiki/rest/api/space/DOC/content/page"), "Should use space-scoped API: \(url)")
        XCTAssertTrue(url.contains("depth=root"), "Should restrict to root depth: \(url)")
        XCTAssertTrue(url.contains("status=current"), "Should filter by status: \(url)")
        XCTAssertFalse(url.contains("spaceKey="), "Must NOT use global content search: \(url)")
    }

    func testCloudRestrictedChildPageIDsScopedToParent() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [
            { "id": "500",
              "restrictions": { "read": { "restrictions": { "user": {"size": 3}, "group": {"size": 0} } },
                                 "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } } } }
          ],
          "start": 0, "size": 1, "_links": {}
        }
        """
        stub.responses["/wiki/rest/api/content/42/child/page"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let ids = try await client.restrictedChildPageIDs(pageId: "42", status: "current", limiter: RateLimiter())
        XCTAssertTrue(ids.contains("500"))
        XCTAssertEqual(ids.count, 1)
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/wiki/rest/api/content/42/child/page"), "Should use parent-scoped API: \(url)")
        XCTAssertFalse(url.contains("depth="), "Child endpoint does not need depth param: \(url)")
    }

    func testCloudRestrictedPageIDsContinuesPagingWhenLinksEnvelopeAbsent() async throws {
        // Regression: a full first page (size == limit) that omits the `_links`
        // envelope entirely must NOT terminate pagination. Restricted IDs on
        // later pages would otherwise be missed, leaking restricted pages.
        let stub = ConfluenceStubTransport()
        let limit = 50
        func unrestricted(_ id: String) -> String {
            """
            { "id": "\(id)",
              "restrictions": { "read":   { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } },
                                 "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } } } }
            """
        }
        func restricted(_ id: String) -> String {
            """
            { "id": "\(id)",
              "restrictions": { "read":   { "restrictions": { "user": {"size": 1}, "group": {"size": 0} } },
                                 "update": { "restrictions": { "user": {"size": 0}, "group": {"size": 0} } } } }
            """
        }
        // Page 1: exactly `limit` items, one restricted ("r0"), and NO `_links`.
        var page1Items = (0..<(limit - 1)).map { unrestricted("u\($0)") }
        page1Items.append(restricted("r0"))
        let page1 = "{ \"results\": [\(page1Items.joined(separator: ","))], \"start\": 0, \"size\": \(limit) }"
        // Page 2: a short page (terminates) with another restricted id ("r1").
        let page2 = "{ \"results\": [\(restricted("r1"))], \"start\": \(limit), \"size\": 1, \"_links\": {} }"

        stub.responses["start=0&limit=\(limit)"] = (200, Data(page1.utf8))
        stub.responses["start=\(limit)&limit=\(limit)"] = (200, Data(page2.utf8))

        let client = cloudClient(stub)
        let ids = try await client.restrictedRootPageIDs(spaceKey: "DOC", status: "current", limiter: RateLimiter())
        XCTAssertTrue(ids.contains("r0"), "Page 1 restricted id must be collected")
        XCTAssertTrue(ids.contains("r1"), "Page 2 restricted id must be collected even though page 1 had no _links")
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(stub.requests.count, 2, "Should fetch both pages")
    }

    func testCloudRestrictedPageIDsReturnsEmptyForDC() async throws {
        let stub = ConfluenceStubTransport()
        let client = dcClient(stub)
        let rootIDs = try await client.restrictedRootPageIDs(spaceKey: "TEAM", status: "current", limiter: RateLimiter())
        let childIDs = try await client.restrictedChildPageIDs(pageId: "1", status: "current", limiter: RateLimiter())
        XCTAssertTrue(rootIDs.isEmpty, "DC must return empty set for restrictedRootPageIDs")
        XCTAssertTrue(childIDs.isEmpty, "DC must return empty set for restrictedChildPageIDs")
        XCTAssertTrue(stub.requests.isEmpty, "DC must not call any API")
    }

    // MARK: - attachmentSize (unknown-size probe)

    func testAttachmentSizeUsesHeadAndParsesContentLength() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/download/att1"] = (200, Data())
        stub.responseHeaders["/download/att1"] = ["Content-Length": "123456"]
        let client = cloudClient(stub)
        let att = ConfluenceAttachment(id: "att1", title: "f.bin", fileSize: nil, downloadLink: "/download/att1")

        let size = try await client.attachmentSize(att)
        XCTAssertEqual(size, 123456)
        XCTAssertEqual(stub.requests.last?.httpMethod, "HEAD", "Size probe must use HEAD, never a body-returning GET")
    }

    func testAttachmentSizeReturnsNilWhenContentLengthMissing() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/download/att2"] = (200, Data())
        let client = cloudClient(stub)
        let att = ConfluenceAttachment(id: "att2", title: "f.bin", fileSize: nil, downloadLink: "/download/att2")

        let size = try await client.attachmentSize(att)
        XCTAssertNil(size, "Without Content-Length the size is undeterminable")
    }

    func testDownloadAttachmentSetsRangeHeader() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/download/att3"] = (206, Data([1, 2, 3, 4]))
        let client = cloudClient(stub)
        let att = ConfluenceAttachment(id: "att3", title: "f.bin", fileSize: 1_000_000, downloadLink: "/download/att3")

        let result = try await client.downloadAttachment(att, range: 10..<14)
        XCTAssertEqual(Array(result.data), [1, 2, 3, 4])
        XCTAssertTrue(result.isPartial, "A 206 response is a partial range")
        XCTAssertEqual(stub.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=10-13")
    }

    // MARK: - Scoped API token gateway

    private func scopedCloudClient(_ stub: ConfluenceStubTransport) -> ConfluenceRESTClient {
        let cfg = ConfluenceInstanceConfig(
            name: "cloud",
            baseURL: URL(string: "https://example.atlassian.net")!,
            edition: .cloud,
            scopedToken: true
        )
        return ConfluenceRESTClient(config: cfg, auth: APITokenAuth(email: "x", token: "y"), transport: stub)
    }

    func testScopedTokenRoutesRESTThroughGateway() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/_edge/tenant_info"] = (200, Data(#"{"cloudId":"cid-1"}"#.utf8))
        stub.responses["/wiki/api/v2/spaces"] = (200, Data(#"{"results":[{"id":"100","key":"DOC","name":"Docs","type":"global"}]}"#.utf8))

        let page = try await scopedCloudClient(stub).listSpaces(cursor: nil, limit: 25)

        XCTAssertEqual(page.items.first?.key, "DOC")
        XCTAssertEqual(stub.requests.first?.url?.absoluteString,
                       "https://example.atlassian.net/_edge/tenant_info")
        XCTAssertEqual(stub.requests.last?.url?.absoluteString,
                       "https://api.atlassian.com/ex/confluence/cid-1/wiki/api/v2/spaces?limit=25")
    }

    func testScopedTokenResolvesCloudIDOnlyOnce() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/_edge/tenant_info"] = (200, Data(#"{"cloudId":"cid-1"}"#.utf8))
        stub.responses["/wiki/api/v2/spaces"] = (200, Data(#"{"results":[]}"#.utf8))
        let client = scopedCloudClient(stub)

        _ = try await client.listSpaces(cursor: nil, limit: 25)
        _ = try await client.listSpaces(cursor: nil, limit: 25)

        let tenantInfoCalls = stub.requests.filter { $0.url?.path == "/_edge/tenant_info" }
        XCTAssertEqual(tenantInfoCalls.count, 1, "The cloud ID must be cached after the first lookup")
    }

    func testScopedTokenKeepsGatewayContextPathForAttachmentLinks() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/_edge/tenant_info"] = (200, Data(#"{"cloudId":"cid-1"}"#.utf8))
        stub.responses["/download/rel"] = (200, Data([7, 7]))
        let att = ConfluenceAttachment(id: "r", title: "f.bin", fileSize: nil, downloadLink: "/download/rel")

        let result = try await scopedCloudClient(stub).downloadAttachment(att, range: nil)

        XCTAssertEqual(Array(result.data), [7, 7])
        XCTAssertEqual(stub.requests.last?.url?.absoluteString,
                       "https://api.atlassian.com/ex/confluence/cid-1/wiki/download/rel")
    }

    func testScopedTokenPropagatesTenantInfoFailure() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/_edge/tenant_info"] = (404, Data())
        stub.responses["/wiki/api/v2/spaces"] = (200, Data(#"{"results":[]}"#.utf8))

        do {
            _ = try await scopedCloudClient(stub).listSpaces(cursor: nil, limit: 25)
            XCTFail("Expected the cloud ID lookup to fail")
        } catch let error as AtlassianError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testUnscopedCloudClientDoesNotUseGateway() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/wiki/api/v2/spaces"] = (200, Data(#"{"results":[]}"#.utf8))

        _ = try await cloudClient(stub).listSpaces(cursor: nil, limit: 25)

        XCTAssertEqual(stub.requests.count, 1, "No tenant_info lookup for legacy API tokens")
        XCTAssertEqual(stub.requests.last?.url?.host, "example.atlassian.net")
    }

    // MARK: - resolveURL / downloadAttachment URL validation (credential-leak prevention)


    func testDownloadAttachmentAcceptsRelativeLink() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/download/rel"] = (200, Data([7, 7]))
        let client = cloudClient(stub)
        let att = ConfluenceAttachment(id: "r", title: "f.bin", fileSize: nil, downloadLink: "/download/rel")
        let result = try await client.downloadAttachment(att, range: nil)
        XCTAssertEqual(Array(result.data), [7, 7])
        // Cloud root-relative links must resolve under the `/wiki` context path.
        XCTAssertEqual(stub.requests.last?.url?.absoluteString,
                       "https://example.atlassian.net/wiki/download/rel")
    }

    func testCloudDownloadLinkGetsWikiContextPrefix() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/wiki/rest/api/content/1/child/attachment/att2/download"] = (200, Data([1]))
        let client = cloudClient(stub)
        // The form Confluence Cloud actually returns for some attachments.
        let att = ConfluenceAttachment(id: "att2", title: "f.bin", fileSize: 1,
                                       downloadLink: "/rest/api/content/1/child/attachment/att2/download")
        _ = try await client.downloadAttachment(att, range: nil)
        XCTAssertEqual(stub.requests.last?.url?.absoluteString,
                       "https://example.atlassian.net/wiki/rest/api/content/1/child/attachment/att2/download")
    }

    func testCloudDownloadLinkAlreadyWikiIsNotDoublePrefixed() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/wiki/download/already"] = (200, Data([2]))
        let client = cloudClient(stub)
        let att = ConfluenceAttachment(id: "w", title: "f.bin", fileSize: 1, downloadLink: "/wiki/download/already")
        _ = try await client.downloadAttachment(att, range: nil)
        XCTAssertEqual(stub.requests.last?.url?.absoluteString,
                       "https://example.atlassian.net/wiki/download/already")
    }

    func testDCDownloadLinkResolvesWithoutWikiPrefix() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/download/dc"] = (200, Data([3]))
        let client = dcClient(stub)
        let att = ConfluenceAttachment(id: "d", title: "f.bin", fileSize: 1, downloadLink: "/download/dc")
        _ = try await client.downloadAttachment(att, range: nil)
        // DC has no `/wiki` context: the link resolves against the base as-is.
        XCTAssertEqual(stub.requests.last?.url?.absoluteString,
                       "https://wiki.example.com/download/dc")
    }

    func testDownloadAttachmentAcceptsSameOriginAbsolute() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/download/abs"] = (200, Data([8]))
        let client = cloudClient(stub)
        let att = ConfluenceAttachment(id: "a", title: "f.bin", fileSize: nil,
                                       downloadLink: "https://example.atlassian.net:443/download/abs")
        let result = try await client.downloadAttachment(att, range: nil)
        XCTAssertEqual(Array(result.data), [8])
    }

    func testDownloadAttachmentRejectsCrossHost() async throws {
        try await assertConfluenceDownloadRejected("https://evil.example.com/download/x")
    }

    func testDownloadAttachmentRejectsSchemeDowngrade() async throws {
        try await assertConfluenceDownloadRejected("http://example.atlassian.net/download/x")
    }

    func testDownloadAttachmentRejectsDifferentPort() async throws {
        try await assertConfluenceDownloadRejected("https://example.atlassian.net:8443/download/x")
    }

    func testDownloadAttachmentRejectsEmbeddedUserInfo() async throws {
        try await assertConfluenceDownloadRejected("https://user:pass@example.atlassian.net/download/x")
    }

    private func assertConfluenceDownloadRejected(_ downloadLink: String,
                                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        let stub = ConfluenceStubTransport()
        let client = cloudClient(stub)
        let att = ConfluenceAttachment(id: "x", title: "f.bin", fileSize: nil, downloadLink: downloadLink)
        do {
            _ = try await client.downloadAttachment(att, range: nil)
            XCTFail("expected invalidURL", file: file, line: line)
        } catch let error as AtlassianError {
            XCTAssertEqual(error, .invalidURL, file: file, line: line)
        }
        XCTAssertTrue(stub.requests.isEmpty, "credential-bearing request must not be sent", file: file, line: line)
    }

    // MARK: - HTTPS-only credential enforcement (config.baseURL hand-edited to http://)

    func testHTTPBaseURLRejectedBeforeSendingCredentials() async throws {
        let stub = ConfluenceStubTransport()
        stub.responses["/wiki/api/v2/spaces"] = (200, Data(#"{"results":[],"_links":{}}"#.utf8))
        let cfg = ConfluenceInstanceConfig(
            name: "insecure",
            baseURL: URL(string: "http://example.atlassian.net")!,
            edition: .cloud
        )
        let client = ConfluenceRESTClient(config: cfg, auth: APITokenAuth(email: "x", token: "y"), transport: stub)
        do {
            _ = try await client.listSpaces(cursor: nil, limit: 25)
            XCTFail("expected invalidURL for http:// base URL")
        } catch let error as AtlassianError {
            XCTAssertEqual(error, .invalidURL)
        }
        XCTAssertTrue(stub.requests.isEmpty, "credential-bearing request must not be sent over http://")
    }

    // MARK: - Folders

    func testCloudListPageDirectChildrenMixedPagesAndFolders() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [
            {
              "id": "p2", "title": "Child Page", "type": "page",
              "spaceId": "100", "parentId": "p1",
              "version": {"number": 5},
              "_links": {"webui": "/spaces/ENG/pages/p2"}
            },
            {"id": "f1", "title": "Engineering", "type": "folder", "spaceId": "100"},
            {"id": "w1", "title": "Board",       "type": "whiteboard", "spaceId": "100"}
          ],
          "_links": {}
        }
        """
        stub.responses["/wiki/api/v2/pages/p1/direct-children"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let page = try await client.listPageDirectChildren(pageId: "p1", cursor: nil, limit: 25)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.items[0].contentType, .page)
        XCTAssertEqual(page.items[0].version, 5)
        XCTAssertEqual(page.items[1].contentType, .folder)
        XCTAssertEqual(page.items[1].title, "Engineering")
        XCTAssertEqual(page.items[2].contentType, .whiteboard)
        XCTAssertEqual(page.items[2].title, "Board")
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/wiki/api/v2/pages/p1/direct-children"), "URL was \(url)")
    }

    func testDCListPageDirectChildrenAlwaysEmpty() async throws {
        let stub = ConfluenceStubTransport()
        let client = dcClient(stub)
        let page = try await client.listPageDirectChildren(pageId: "p1", cursor: nil, limit: 25)
        XCTAssertTrue(page.items.isEmpty, "DC should always return no children")
        XCTAssertTrue(stub.requests.isEmpty, "DC should make no API call for folders")
    }

    func testCloudListFolderChildrenMixedPagesAndFolders() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [
            {
              "id": "p1", "title": "RFC-001", "type": "page",
              "spaceId": "100", "parentId": "f1",
              "version": {"number": 3},
              "_links": {"webui": "/spaces/ENG/pages/p1"}
            },
            {
              "id": "f2", "title": "Archive", "type": "folder",
              "spaceId": "100", "parentId": "f1"
            }
          ],
          "_links": {}
        }
        """
        stub.responses["/wiki/api/v2/folders/f1/direct-children"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let page = try await client.listFolderChildren(folderId: "f1", cursor: nil, limit: 25)
        XCTAssertEqual(page.items.count, 2)
        let pageItem = page.items.first
        XCTAssertEqual(pageItem?.contentType, .page)
        XCTAssertEqual(pageItem?.id, "p1")
        XCTAssertEqual(pageItem?.version, 3)
        let folderItem = page.items.last
        XCTAssertEqual(folderItem?.contentType, .folder)
        XCTAssertEqual(folderItem?.id, "f2")
        XCTAssertEqual(folderItem?.title, "Archive")
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/wiki/api/v2/folders/f1/direct-children"), "URL was \(url)")
    }

    func testDCListFolderChildrenAlwaysEmpty() async throws {
        let stub = ConfluenceStubTransport()
        let client = dcClient(stub)
        let page = try await client.listFolderChildren(folderId: "f1", cursor: nil, limit: 25)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: - Whiteboards

    func testCloudListWhiteboardChildrenMixedTypes() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [
            {
              "id": "p9", "title": "Notes", "type": "page",
              "spaceId": "100", "parentId": "w1",
              "version": {"number": 2},
              "_links": {"webui": "/spaces/ENG/pages/p9"}
            },
            {"id": "w2", "title": "Sub Board", "type": "whiteboard", "spaceId": "100", "parentId": "w1"},
            {"id": "d1", "title": "Data",      "type": "database",   "spaceId": "100"}
          ],
          "_links": {}
        }
        """
        stub.responses["/wiki/api/v2/whiteboards/w1/direct-children"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let page = try await client.listWhiteboardChildren(whiteboardId: "w1", cursor: nil, limit: 25)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.items[0].contentType, .page)
        XCTAssertEqual(page.items[1].contentType, .whiteboard)
        XCTAssertEqual(page.items[1].id, "w2")
        XCTAssertEqual(page.items[2].contentType, .database)
        XCTAssertEqual(page.items[2].id, "d1")
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/wiki/api/v2/whiteboards/w1/direct-children"), "URL was \(url)")
    }

    func testDCListWhiteboardChildrenAlwaysEmpty() async throws {
        let stub = ConfluenceStubTransport()
        let client = dcClient(stub)
        let page = try await client.listWhiteboardChildren(whiteboardId: "w1", cursor: nil, limit: 25)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertTrue(stub.requests.isEmpty, "DC should make no API call for whiteboards")
    }

    func testCloudGetWhiteboard() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "id": "w1", "title": "Design Board", "spaceId": "100", "parentId": "p1",
          "authorId": "acc-1", "createdAt": "2024-05-06T07:08:09.000Z",
          "_links": {"webui": "/spaces/ENG/whiteboards/w1"}
        }
        """
        stub.responses["/wiki/api/v2/whiteboards/w1"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let whiteboard = try await client.getWhiteboard(id: "w1")
        XCTAssertEqual(whiteboard.id, "w1")
        XCTAssertEqual(whiteboard.title, "Design Board")
        XCTAssertEqual(whiteboard.spaceId, "100")
        XCTAssertEqual(whiteboard.parentId, "p1")
        XCTAssertEqual(whiteboard.authorId, "acc-1")
        XCTAssertEqual(whiteboard.createdAt, "2024-05-06T07:08:09.000Z")
        XCTAssertEqual(whiteboard.webURL, "/spaces/ENG/whiteboards/w1")
    }

    func testCloudGetWhiteboardEpochMillisCreatedAt() async throws {
        let stub = ConfluenceStubTransport()
        // The whiteboard endpoint returns `createdAt` as epoch milliseconds (a
        // JSON number), unlike pages which return an ISO 8601 string.
        let json = """
        {
          "id": "w1", "title": "Design Board", "spaceId": "100", "parentId": "p1",
          "authorId": "acc-1", "createdAt": 1786800386358,
          "_links": {"webui": "/spaces/ENG/whiteboards/w1"}
        }
        """
        stub.responses["/wiki/api/v2/whiteboards/w1"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let whiteboard = try await client.getWhiteboard(id: "w1")
        XCTAssertEqual(whiteboard.id, "w1")
        XCTAssertEqual(whiteboard.createdAt, "2026-08-15T13:26:26.358Z")
    }

    func testDCGetWhiteboardThrowsNotFound() async throws {
        let stub = ConfluenceStubTransport()
        let client = dcClient(stub)
        do {
            _ = try await client.getWhiteboard(id: "w1")
            XCTFail("expected notFound on Data Center")
        } catch let error as AtlassianError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: - Databases

    func testCloudListDatabaseChildrenMixedTypes() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "results": [
            {
              "id": "p9", "title": "Notes", "type": "page",
              "spaceId": "100", "parentId": "d1",
              "version": {"number": 2},
              "_links": {"webui": "/spaces/ENG/pages/p9"}
            },
            {"id": "d2", "title": "Sub Data", "type": "database",  "spaceId": "100", "parentId": "d1"},
            {"id": "e1", "title": "Link",     "type": "embed",     "spaceId": "100"}
          ],
          "_links": {}
        }
        """
        stub.responses["/wiki/api/v2/databases/d1/direct-children"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let page = try await client.listDatabaseChildren(databaseId: "d1", cursor: nil, limit: 25)
        XCTAssertEqual(page.items.count, 3)
        XCTAssertEqual(page.items[0].contentType, .page)
        XCTAssertEqual(page.items[1].contentType, .database)
        XCTAssertEqual(page.items[1].id, "d2")
        XCTAssertEqual(page.items[2].contentType, .other)
        let url = stub.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/wiki/api/v2/databases/d1/direct-children"), "URL was \(url)")
    }

    func testDCListDatabaseChildrenAlwaysEmpty() async throws {
        let stub = ConfluenceStubTransport()
        let client = dcClient(stub)
        let page = try await client.listDatabaseChildren(databaseId: "d1", cursor: nil, limit: 25)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertTrue(stub.requests.isEmpty, "DC should make no API call for databases")
    }

    func testCloudGetDatabase() async throws {
        let stub = ConfluenceStubTransport()
        let json = """
        {
          "id": "d1", "title": "Bug Tracker", "spaceId": "100", "parentId": "p1",
          "authorId": "acc-1", "ownerId": "acc-2",
          "createdAt": "2024-05-06T07:08:09.000Z",
          "version": {"number": 7},
          "_links": {"webui": "/spaces/ENG/database/d1"}
        }
        """
        stub.responses["/wiki/api/v2/databases/d1"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let database = try await client.getDatabase(id: "d1")
        XCTAssertEqual(database.id, "d1")
        XCTAssertEqual(database.title, "Bug Tracker")
        XCTAssertEqual(database.spaceId, "100")
        XCTAssertEqual(database.parentId, "p1")
        XCTAssertEqual(database.authorId, "acc-1")
        XCTAssertEqual(database.ownerId, "acc-2")
        XCTAssertEqual(database.version, 7)
        XCTAssertEqual(database.createdAt, "2024-05-06T07:08:09.000Z")
        XCTAssertEqual(database.webURL, "/spaces/ENG/database/d1")
    }

    func testCloudGetDatabaseEpochMillisCreatedAt() async throws {
        let stub = ConfluenceStubTransport()
        // As with whiteboards, `createdAt` may come back as epoch milliseconds
        // (a JSON number) instead of an ISO 8601 string.
        let json = """
        {
          "id": "d1", "title": "Bug Tracker", "spaceId": "100",
          "authorId": "acc-1", "createdAt": 1786800386358
        }
        """
        stub.responses["/wiki/api/v2/databases/d1"] = (200, Data(json.utf8))
        let client = cloudClient(stub)
        let database = try await client.getDatabase(id: "d1")
        XCTAssertEqual(database.id, "d1")
        XCTAssertEqual(database.createdAt, "2026-08-15T13:26:26.358Z")
        XCTAssertNil(database.version)
        XCTAssertNil(database.webURL)
    }

    func testDCGetDatabaseThrowsNotFound() async throws {
        let stub = ConfluenceStubTransport()
        let client = dcClient(stub)
        do {
            _ = try await client.getDatabase(id: "d1")
            XCTFail("expected notFound on Data Center")
        } catch let error as AtlassianError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

}
