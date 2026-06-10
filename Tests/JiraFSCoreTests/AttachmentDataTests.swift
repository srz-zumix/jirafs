import XCTest
@testable import JiraAPI
@testable import JiraFSCore

/// Stub `JiraClient` that serves a fixed attachment blob and records every
/// `downloadAttachment` call (including the requested range) so tests can assert
/// the OOM-guard behaviour: small attachments are downloaded once and cached;
/// large attachments are streamed via bounded Range requests and never cached.
private final actor StubAttachmentClient: JiraClient {
    let config = JiraInstanceConfig(
        name: "stub",
        baseURL: URL(string: "https://stub.example.com")!,
        edition: .cloud
    )
    private let blob: Data
    private(set) var calls: [Range<Int>?] = []

    init(blob: Data) { self.blob = blob }

    var callSnapshot: [Range<Int>?] { get async { calls } }

    func serverInfo() async throws {}
    func listProjects() async throws -> [JiraProject] { [] }
    func getProject(key: String) async throws -> JiraProject { JiraProject(id: "1", key: key, name: key) }
    func searchIssues(jql: String, nextPageToken: String?, maxResults: Int, fields: [String]?) async throws -> JiraSearchResult {
        JiraSearchResult(issues: [])
    }
    func getIssue(key: String) async throws -> JiraIssue { JiraIssue(id: key, key: key, fields: JiraIssueFields()) }
    func listComments(issueKey: String) async throws -> [JiraComment] { [] }
    func listAttachments(issueKey: String) async throws -> [JiraAttachment] { [] }
    func listFields() async throws -> [JiraField] { [] }

    func downloadAttachment(_ attachment: JiraAttachment, range: Range<Int>?) async throws -> Data {
        calls.append(range)
        guard let range else { return blob }
        let lo = min(max(range.lowerBound, 0), blob.count)
        let hi = min(max(range.upperBound, lo), blob.count)
        return blob.subdata(in: lo..<hi)
    }
}

private func attachment(id: String, size: Int) -> JiraAttachment {
    JiraAttachment(id: id, filename: "f.bin", size: size, mimeType: nil, content: nil, created: nil, author: nil)
}

private func makeDataSource(_ client: StubAttachmentClient, maxInline: Int) -> IssueDataSource {
    IssueDataSource(
        client: client,
        cache: CacheManager(),
        ttl: .default,
        maxInlineAttachmentBytes: maxInline,
        limiter: RateLimiter(maxRetries: 0)
    )
}

final class AttachmentDataTests: XCTestCase {
    private let blob = Data((0..<10).map { UInt8($0) }) // bytes 0..9

    /// Small (size <= maxInline): one full download, cached, sliced locally;
    /// the second read issues no further network call.
    func testSmallAttachmentCachesAndSlices() async throws {
        let client = StubAttachmentClient(blob: blob)
        let ds = makeDataSource(client, maxInline: 1024)
        let att = attachment(id: "a1", size: blob.count)

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])

        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7])

        let calls = await client.callSnapshot
        XCTAssertEqual(calls.count, 1, "Small attachment must download once and then serve slices from cache")
        XCTAssertNil(calls.first ?? nil, "The single download must fetch the whole file (range == nil)")
    }

    /// Large (size > maxInline): every read is a bounded Range request and the
    /// bytes are never cached, so the extension never buffers the whole file.
    func testLargeAttachmentStreamsAndNeverCaches() async throws {
        let client = StubAttachmentClient(blob: blob)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a2", size: blob.count)

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])

        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7])

        let calls = await client.callSnapshot
        XCTAssertEqual(calls.count, 2, "Each read of a large attachment must hit the network (no caching)")
        XCTAssertEqual(calls[0], 0..<4)
        XCTAssertEqual(calls[1], 4..<8)
        XCTAssertFalse(calls.contains(where: { $0 == nil }), "Large attachment must never trigger a full download")
    }

    /// An empty (size 0) attachment is inlineable and returns empty cleanly.
    func testEmptyAttachmentReturnsEmpty() async throws {
        let client = StubAttachmentClient(blob: Data())
        let ds = makeDataSource(client, maxInline: 1024)
        let att = attachment(id: "a3", size: 0)

        let data = try await ds.attachmentData(att, range: nil)
        XCTAssertTrue(data.isEmpty)
    }

    /// A large attachment with no range must be rejected rather than fully
    /// downloaded — this is the OOM/DoS guard.
    func testLargeAttachmentWithNilRangeThrows() async throws {
        let client = StubAttachmentClient(blob: blob)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a4", size: blob.count)

        do {
            _ = try await ds.attachmentData(att, range: nil)
            XCTFail("Expected attachmentData to throw for a large attachment with nil range")
        } catch let error as JiraAPIError {
            XCTAssertEqual(error, .unsupported)
        }
        let calls = await client.callSnapshot
        XCTAssertTrue(calls.isEmpty, "No download must be issued when the guard rejects the request")
    }
}
