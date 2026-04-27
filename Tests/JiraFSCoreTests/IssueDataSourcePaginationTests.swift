import XCTest
@testable import JiraAPI
@testable import JiraFSCore

/// Stub `JiraClient` that returns synthetic paginated issues without any
/// network/JSON cost. Useful to measure pagination loop overhead in
/// `IssueDataSource.issueKeys(forProject:)` for very large projects.
private final actor StubPaginatedClient: JiraClient {
    let config: JiraInstanceConfig
    private let total: Int
    private(set) var requestCount: Int = 0

    init(total: Int) {
        self.config = JiraInstanceConfig(
            name: "stub",
            baseURL: URL(string: "https://stub.example.com")!,
            edition: .cloud
        )
        self.total = total
    }

    nonisolated var requestCountSnapshot: Int {
        get async { await self.requestCount }
    }

    func serverInfo() async throws {}
    func listProjects() async throws -> [JiraProject] { [] }
    func getProject(key: String) async throws -> JiraProject {
        JiraProject(id: "1", key: key, name: key)
    }

    func searchIssues(jql: String, startAt: Int, maxResults: Int) async throws -> JiraSearchResult {
        requestCount += 1
        let end = min(startAt + maxResults, total)
        let count = max(0, end - startAt)
        let issues: [JiraIssue] = (0..<count).map { i in
            let n = startAt + i
            return JiraIssue(id: "\(n)", key: "PROJ-\(n)", fields: JiraIssueFields())
        }
        return JiraSearchResult(startAt: startAt, maxResults: maxResults, total: total, issues: issues)
    }

    func getIssue(key: String) async throws -> JiraIssue {
        JiraIssue(id: key, key: key, fields: JiraIssueFields())
    }
    func listComments(issueKey: String) async throws -> [JiraComment] { [] }
    func listAttachments(issueKey: String) async throws -> [JiraAttachment] { [] }
    func downloadAttachment(_ attachment: JiraAttachment, range: Range<Int>?) async throws -> Data { Data() }
}

final class IssueDataSourcePaginationTests: XCTestCase {

    /// Verify pagination collects all keys across many pages and that the
    /// number of HTTP-equivalent calls matches the expected page count.
    func testPaginationCollectsAllKeys() async throws {
        let total = 5_000
        let pageSize = 100
        let stub = StubPaginatedClient(total: total)
        let limiter = RateLimiter(maxRetries: 0)
        let dataSource = IssueDataSource(
            client: stub,
            cache: CacheManager(),
            ttl: .default,
            maxResults: pageSize,
            limiter: limiter
        )
        let keys = try await dataSource.issueKeys(forProject: "PROJ")
        XCTAssertEqual(keys.count, total)
        XCTAssertEqual(keys.first, "PROJ-0")
        XCTAssertEqual(keys.last, "PROJ-\(total - 1)")
        let calls = await stub.requestCountSnapshot
        XCTAssertEqual(calls, total / pageSize)
    }

    /// Verify the second invocation hits the in-memory cache and issues no
    /// additional remote calls.
    func testPaginationIsCachedAcrossCalls() async throws {
        let stub = StubPaginatedClient(total: 1_000)
        let limiter = RateLimiter(maxRetries: 0)
        let dataSource = IssueDataSource(
            client: stub,
            cache: CacheManager(),
            ttl: .default,
            maxResults: 50,
            limiter: limiter
        )
        _ = try await dataSource.issueKeys(forProject: "PROJ")
        let firstCalls = await stub.requestCountSnapshot
        _ = try await dataSource.issueKeys(forProject: "PROJ")
        let secondCalls = await stub.requestCountSnapshot
        XCTAssertEqual(firstCalls, secondCalls, "Second call should be served from cache")
    }

    /// Performance smoke check: paginating 10k issues should complete well
    /// under a generous timeout (1 s on developer hardware). This guards
    /// against accidental quadratic behaviour in the loop.
    func testPaginationLargeProjectIsFast() async throws {
        let total = 10_000
        let pageSize = 100
        let stub = StubPaginatedClient(total: total)
        let limiter = RateLimiter(maxRetries: 0)
        let dataSource = IssueDataSource(
            client: stub,
            cache: CacheManager(),
            ttl: .default,
            maxResults: pageSize,
            limiter: limiter
        )
        let started = Date()
        let keys = try await dataSource.issueKeys(forProject: "BIG")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(keys.count, total)
        XCTAssertLessThan(elapsed, 1.0, "10k-issue pagination took \(elapsed)s; suspect non-linear behaviour")
    }
}
