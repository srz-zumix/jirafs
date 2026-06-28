import XCTest
@testable import JiraAPI

/// In-memory transport stub used by `JiraRESTClient` tests.
final class StubTransport: JiraHTTPTransport, @unchecked Sendable {
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

final class JiraRESTClientTests: XCTestCase {
    func testListProjectsCloud() async throws {
        let stub = StubTransport()
        let json = """
        [{"id":"1","key":"ABC","name":"Alpha"}]
        """
        stub.responses["/rest/api/3/project"] = (200, Data(json.utf8))
        let cfg = JiraInstanceConfig(name: "test", baseURL: URL(string: "https://example.atlassian.net")!, edition: .cloud)
        let client = JiraRESTClient(config: cfg, auth: APITokenAuth(email: "x", token: "y"), transport: stub)
        let projects = try await client.listProjects()
        XCTAssertEqual(projects.first?.key, "ABC")
        XCTAssertEqual(stub.requests.first?.url?.absoluteString, "https://example.atlassian.net/rest/api/3/project")
    }

    func testServerUsesV2() async throws {
        let stub = StubTransport()
        stub.responses["/rest/api/2/project/DEF"] = (200, Data(#"{"id":"2","key":"DEF","name":"Beta"}"#.utf8))
        let cfg = JiraInstanceConfig(name: "srv", baseURL: URL(string: "https://jira.example.com")!, edition: .server)
        let client = JiraRESTClient(config: cfg, auth: PATAuth(token: "tok"), transport: stub)
        let project = try await client.getProject(key: "DEF")
        XCTAssertEqual(project.key, "DEF")
    }

    func testNotFoundMaps() async throws {
        let stub = StubTransport()
        let cfg = JiraInstanceConfig(name: "test", baseURL: URL(string: "https://example.atlassian.net")!, edition: .cloud)
        let client = JiraRESTClient(config: cfg, auth: PATAuth(token: "x"), transport: stub)
        do {
            _ = try await client.getProject(key: "MISSING")
            XCTFail("expected error")
        } catch let error as JiraAPIError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - downloadAttachment URL validation (credential-leak prevention)

    private func cloudClient(_ stub: StubTransport) -> JiraRESTClient {
        let cfg = JiraInstanceConfig(name: "test", baseURL: URL(string: "https://example.atlassian.net")!, edition: .cloud)
        return JiraRESTClient(config: cfg, auth: APITokenAuth(email: "x", token: "y"), transport: stub)
    }

    private func attachment(content: String?) -> JiraAttachment {
        JiraAttachment(id: "1", filename: "f.txt", size: 4, mimeType: nil, content: content, created: nil, author: nil)
    }

    func testDownloadAttachmentAcceptsSameOrigin() async throws {
        let stub = StubTransport()
        stub.responses["/secure/attachment/1/f.txt"] = (200, Data([1, 2, 3, 4]))
        let client = cloudClient(stub)
        let result = try await client.downloadAttachment(
            attachment(content: "https://example.atlassian.net/secure/attachment/1/f.txt"), range: nil)
        XCTAssertEqual(Array(result.data), [1, 2, 3, 4])
        XCTAssertFalse(result.isPartial, "A 200 response is a full body, not a partial range")
    }

    func testDownloadAttachmentAcceptsExplicitDefaultPort() async throws {
        let stub = StubTransport()
        stub.responses["/secure/att443"] = (200, Data([9]))
        let client = cloudClient(stub)
        let result = try await client.downloadAttachment(
            attachment(content: "https://example.atlassian.net:443/secure/att443"), range: nil)
        XCTAssertEqual(Array(result.data), [9])
    }

    func testDownloadAttachmentRejectsCrossHost() async throws {
        try await assertDownloadRejected(content: "https://evil.example.com/secure/x")
    }

    func testDownloadAttachmentRejectsSchemeDowngrade() async throws {
        try await assertDownloadRejected(content: "http://example.atlassian.net/secure/x")
    }

    func testDownloadAttachmentRejectsDifferentPort() async throws {
        try await assertDownloadRejected(content: "https://example.atlassian.net:8443/secure/x")
    }

    func testDownloadAttachmentRejectsEmbeddedUserInfo() async throws {
        try await assertDownloadRejected(content: "https://user:pass@example.atlassian.net/secure/x")
    }

    func testDownloadAttachmentRejectsMissingContent() async throws {
        try await assertDownloadRejected(content: nil)
    }

    // MARK: - HTTPS-only credential enforcement (config.baseURL hand-edited to http://)

    func testHTTPBaseURLRejectedBeforeSendingCredentials() async throws {
        let stub = StubTransport()
        stub.responses["/rest/api/3/project"] = (200, Data("[]".utf8))
        let cfg = JiraInstanceConfig(name: "insecure", baseURL: URL(string: "http://example.atlassian.net")!, edition: .cloud)
        let client = JiraRESTClient(config: cfg, auth: APITokenAuth(email: "x", token: "y"), transport: stub)
        do {
            _ = try await client.listProjects()
            XCTFail("expected invalidURL for http:// base URL")
        } catch let error as JiraAPIError {
            XCTAssertEqual(error, .invalidURL)
        }
        XCTAssertTrue(stub.requests.isEmpty, "credential-bearing request must not be sent over http://")
    }

    private func assertDownloadRejected(content: String?,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let stub = StubTransport()
        let client = cloudClient(stub)
        do {
            _ = try await client.downloadAttachment(attachment(content: content), range: nil)
            XCTFail("expected invalidURL", file: file, line: line)
        } catch let error as JiraAPIError {
            XCTAssertEqual(error, .invalidURL, file: file, line: line)
        }
        XCTAssertTrue(stub.requests.isEmpty, "credential-bearing request must not be sent", file: file, line: line)
    }
}
