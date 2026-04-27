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
}
