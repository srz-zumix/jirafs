import XCTest
@testable import AtlassianCore
@testable import JiraAPI
@testable import JiraFSCore

/// Stub `JiraClient` that serves a fixed attachment blob and records every
/// `downloadAttachment` (ranged) call, so tests can assert how `IssueDataSource`
/// delegates to the shared in-memory `AttachmentByteCache`.
private final actor StubAttachmentClient: JiraClient {
    let config = JiraInstanceConfig(
        name: "stub",
        baseURL: URL(string: "https://stub.example.com")!,
        edition: .cloud
    )
    private let blob: Data
    /// When `false`, the stub models a server that ignores `Range` and returns
    /// the whole body with `isPartial == false` (HTTP 200) for ranged requests.
    private let honorsRange: Bool
    private(set) var rangedCalls: [Range<Int>?] = []

    init(blob: Data, honorsRange: Bool = true) {
        self.blob = blob
        self.honorsRange = honorsRange
    }

    var rangedSnapshot: [Range<Int>?] { get async { rangedCalls } }

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

    func downloadAttachment(_ attachment: JiraAttachment, range: Range<Int>?) async throws -> RangedDownload {
        rangedCalls.append(range)
        guard honorsRange, let range else {
            // Server ignored Range (or no range requested): full body, 200.
            return RangedDownload(data: blob, isPartial: false)
        }
        let lo = min(max(range.lowerBound, 0), blob.count)
        let hi = min(max(range.upperBound, lo), blob.count)
        return RangedDownload(data: blob.subdata(in: lo..<hi), isPartial: true)
    }
}

private func attachment(id: String, size: Int) -> JiraAttachment {
    JiraAttachment(id: id, filename: "f.bin", size: size, mimeType: nil, content: nil, created: nil, author: nil)
}

final class AttachmentDataTests: XCTestCase {
    private let blob = Data((0..<10).map { UInt8($0) }) // bytes 0..9

    /// Builds an `IssueDataSource` and registers a teardown that clears the
    /// shared `AttachmentByteCache`, so cached bodies don't survive between tests.
    private func makeDataSource(_ client: StubAttachmentClient, maxInline: Int) -> IssueDataSource {
        let ds = IssueDataSource(
            client: client,
            cache: CacheManager(),
            ttl: .default,
            maxInlineAttachmentBytes: maxInline,
            limiter: RateLimiter(maxRetries: 0)
        )
        addTeardownBlock { await ds.synchronize() }
        return ds
    }

    /// Small (size <= maxInline): the whole body is fetched once via a single
    /// `rangeFetch(nil)`, cached in memory, and subsequent reads are sliced
    /// locally without any further network call.
    func testSmallAttachmentCachesInMemoryAndSlices() async throws {
        let client = StubAttachmentClient(blob: blob)
        let ds = makeDataSource(client, maxInline: 1024)
        let att = attachment(id: "a1", size: blob.count)

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])
        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7])

        let rangedCalls = await client.rangedSnapshot
        XCTAssertEqual(rangedCalls, [nil], "Small attachment must fetch the whole body once, then slice from memory")
    }

    /// Large (size > maxInline) against a Range-honoring server: every read is a
    /// bounded Range request streamed directly, nothing is cached.
    func testLargeAttachmentStreamsViaRange() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a2", size: blob.count)

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])
        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7])

        let ranged = await client.rangedSnapshot
        XCTAssertEqual(ranged, [0..<4, 4..<8], "Each read must issue a bounded Range request")
    }

    /// Unknown-size attachment against a server that ignores Range (200 full
    /// body): the body fits the inline cap, so it is cached in memory after the
    /// first read and subsequent reads are served without re-downloading.
    func testRangeIgnoringServerWithSmallBodyCachesInMemory() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: false)
        let ds = makeDataSource(client, maxInline: 1024)
        let att = attachment(id: "a3", size: -1) // unknown size

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3], "First window sliced from the full 200 body")
        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7], "Second window from the in-memory copy, not the body prefix")

        let ranged = await client.rangedSnapshot
        XCTAssertEqual(ranged.count, 1, "Only the first read hits the network; the rest are served from memory")
    }

    /// Large (size > maxInline) against a Range-ignoring server: the 200 body
    /// exceeds the inline cap, so it is NOT cached. Each read re-fetches but the
    /// returned slices are still correct (degraded, but bounded-memory, behavior).
    func testRangeIgnoringServerWithLargeKnownSizeNotCached() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: false)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a3b", size: blob.count) // size 10 > maxInline 4

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])
        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7], "Second window must be correct even without caching")

        let ranged = await client.rangedSnapshot
        XCTAssertEqual(ranged.count, 2, "A too-large 200 body is not cached, so each read re-fetches")
    }

    /// An empty (size 0) attachment returns empty cleanly.
    func testEmptyAttachmentReturnsEmpty() async throws {
        let client = StubAttachmentClient(blob: Data())
        let ds = makeDataSource(client, maxInline: 1024)
        let att = attachment(id: "a5", size: 0)

        let data = try await ds.attachmentData(att, range: nil)
        XCTAssertTrue(data.isEmpty)
    }

    /// A large attachment with a nil range returns the whole body via a single
    /// `rangeFetch(nil)` (the in-memory buffering happens only at the call
    /// boundary; it is not cached because it exceeds the inline cap).
    func testLargeAttachmentWithNilRangeReturnsWholeBody() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a6", size: blob.count)

        let data = try await ds.attachmentData(att, range: nil)
        XCTAssertEqual(Array(data), Array(blob))
        let ranged = await client.rangedSnapshot
        XCTAssertEqual(ranged, [nil], "A whole-body read must fetch the whole body once")
    }

    /// An unknown-size (nil) attachment read with a nil range also fetches the
    /// whole body once via `rangeFetch(nil)`.
    func testUnknownSizeNilRangeReturnsWholeBody() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a10", size: -1) // size < 0 → unknown (nil)

        let data = try await ds.attachmentData(att, range: nil)
        XCTAssertEqual(Array(data), Array(blob))
        let ranged = await client.rangedSnapshot
        XCTAssertEqual(ranged, [nil], "Unknown-size whole-body read must fetch the whole body once")
    }

    /// A window extending past the known size is clamped to `[start, size)`
    /// before the Range request is issued, so a strict server never sees an
    /// out-of-bounds Range (which would yield `416`).
    func testRangeClampedToKnownSizeBeforeRequest() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a7", size: blob.count) // size 10

        let data = try await ds.attachmentData(att, range: 8..<20)
        XCTAssertEqual(Array(data), [8, 9])
        let ranged = await client.rangedSnapshot
        XCTAssertEqual(ranged, [8..<10], "Range must be clamped to the known size before the request")
    }

    /// A read starting at/after EOF returns empty without issuing any network
    /// request.
    func testReadAtEofReturnsEmptyWithoutRequest() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a8", size: blob.count) // size 10

        let data = try await ds.attachmentData(att, range: 10..<20)
        XCTAssertTrue(data.isEmpty)
        let ranged = await client.rangedSnapshot
        XCTAssertTrue(ranged.isEmpty, "A read at EOF must not hit the network")
    }

    /// When the server ignores Range (200 full body), an over-long window is
    /// still sliced from the in-memory body using the clamped bounds.
    func testRangeClampedWhenServerReturnsFullBody() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: false)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a9", size: blob.count) // size 10

        let data = try await ds.attachmentData(att, range: 8..<20)
        XCTAssertEqual(Array(data), [8, 9], "200 fallback must slice with the clamped range")
    }

    // MARK: - AttachmentByteCache (direct) — LRU / memory budget

    /// The in-memory cache evicts least-recently-used entries to honor the total
    /// budget: with a budget of one max-size entry, caching `b` evicts `a`, so a
    /// later read of `a` re-downloads.
    func testLruEvictionHonorsTotalBudget() async throws {
        let cache = AttachmentByteCache(maxInlineBytes: 10, maxTotalBytes: 10)
        let counter = CallCounter()

        func fetch(_ id: String, byte: UInt8) -> AttachmentByteCache.RangeFetch {
            { _ in
                await counter.bump(id)
                return RangedDownload(data: Data(repeating: byte, count: 10), isPartial: false)
            }
        }

        _ = try await cache.bytes(id: "a", size: 10, range: 0..<10, rangeFetch: fetch("a", byte: 1))
        _ = try await cache.bytes(id: "a", size: 10, range: 0..<10, rangeFetch: fetch("a", byte: 1))
        let aFirst = await counter.count("a")
        XCTAssertEqual(aFirst, 1, "Second read of a must be served from memory")

        // Caching b (10 bytes) exceeds the 10-byte budget, evicting a.
        _ = try await cache.bytes(id: "b", size: 10, range: 0..<10, rangeFetch: fetch("b", byte: 2))
        // a was evicted, so this re-downloads.
        _ = try await cache.bytes(id: "a", size: 10, range: 0..<10, rangeFetch: fetch("a", byte: 1))
        let aSecond = await counter.count("a")
        XCTAssertEqual(aSecond, 2, "a must re-download after being LRU-evicted by b")
    }

    /// `clear()` drops cached bodies, so a subsequent read re-downloads.
    func testClearDropsCachedBodies() async throws {
        let cache = AttachmentByteCache(maxInlineBytes: 1024, maxTotalBytes: 1024)
        let counter = CallCounter()

        func fetch() -> AttachmentByteCache.RangeFetch {
            { _ in
                await counter.bump("x")
                return RangedDownload(data: Data(repeating: 7, count: 8), isPartial: false)
            }
        }

        _ = try await cache.bytes(id: "x", size: 8, range: 0..<8, rangeFetch: fetch())
        _ = try await cache.bytes(id: "x", size: 8, range: 0..<8, rangeFetch: fetch())
        let before = await counter.count("x")
        XCTAssertEqual(before, 1, "Cached read must not re-download")

        await cache.clear()
        _ = try await cache.bytes(id: "x", size: 8, range: 0..<8, rangeFetch: fetch())
        let after = await counter.count("x")
        XCTAssertEqual(after, 2, "clear() must drop the cache so the next read re-downloads")
    }
}

/// Counts how many times a fetch closure was invoked, keyed by attachment id.
private actor CallCounter {
    private var counts: [String: Int] = [:]
    func bump(_ id: String) { counts[id, default: 0] += 1 }
    func count(_ id: String) -> Int { counts[id] ?? 0 }
}
