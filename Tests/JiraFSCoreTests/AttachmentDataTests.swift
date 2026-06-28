import XCTest
@testable import AtlassianCore
@testable import JiraAPI
@testable import JiraFSCore

/// Stub `JiraClient` that serves a fixed attachment blob and records every
/// `downloadAttachment` (ranged) and `downloadAttachmentToFile` (whole-body)
/// call, so tests can assert how `IssueDataSource` delegates to the shared
/// `AttachmentByteCache`.
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
    private(set) var fileCalls: Int = 0

    init(blob: Data, honorsRange: Bool = true) {
        self.blob = blob
        self.honorsRange = honorsRange
    }

    var rangedSnapshot: [Range<Int>?] { get async { rangedCalls } }
    var fileSnapshot: Int { get async { fileCalls } }

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

    func downloadAttachmentToFile(_ attachment: JiraAttachment) async throws -> URL {
        fileCalls += 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try blob.write(to: url, options: .atomic)
        return url
    }
}

private func attachment(id: String, size: Int) -> JiraAttachment {
    JiraAttachment(id: id, filename: "f.bin", size: size, mimeType: nil, content: nil, created: nil, author: nil)
}

final class AttachmentDataTests: XCTestCase {
    private let blob = Data((0..<10).map { UInt8($0) }) // bytes 0..9

    /// Builds an `IssueDataSource` and registers a teardown that clears the
    /// shared `AttachmentByteCache`, so any temp file materialized during the
    /// test is deleted even if the test throws before its final assertion.
    private func makeDataSource(_ client: StubAttachmentClient, maxInline: Int,
                                mode: AttachmentByteCache.Mode = .range) -> IssueDataSource {
        let ds = IssueDataSource(
            client: client,
            cache: CacheManager(),
            ttl: .default,
            maxInlineAttachmentBytes: maxInline,
            attachmentMode: mode,
            limiter: RateLimiter(maxRetries: 0)
        )
        addTeardownBlock { await ds.synchronize() }
        return ds
    }

    /// Small (size <= maxInline) in range mode: downloaded once to a temp file
    /// and sliced locally; the second read issues no further network call.
    func testSmallAttachmentCachesToFileAndSlices() async throws {
        let client = StubAttachmentClient(blob: blob)
        let ds = makeDataSource(client, maxInline: 1024)
        let att = attachment(id: "a1", size: blob.count)

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])
        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7])

        let fileCalls = await client.fileSnapshot
        let rangedCalls = await client.rangedSnapshot
        XCTAssertEqual(fileCalls, 1, "Small attachment must download once to disk then slice locally")
        XCTAssertTrue(rangedCalls.isEmpty, "Small attachment must not issue ranged requests")
    }

    /// Large (size > maxInline) against a Range-honoring server: every read is a
    /// bounded Range request streamed directly, nothing is written to disk.
    func testLargeAttachmentStreamsViaRange() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a2", size: blob.count)

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])
        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7])

        let ranged = await client.rangedSnapshot
        let fileCalls = await client.fileSnapshot
        XCTAssertEqual(ranged, [0..<4, 4..<8], "Each read must issue a bounded Range request")
        XCTAssertEqual(fileCalls, 0, "A Range-honoring server must not trigger a disk fallback")
    }

    /// Large attachment against a server that ignores Range (returns 200 full
    /// body): the body is persisted to disk once and subsequent reads are served
    /// from the file without re-downloading — the second window is NOT the body
    /// prefix, so no corruption.
    func testLargeAttachmentFallsBackToDiskWhenRangeIgnored() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: false)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a3", size: blob.count)

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3], "First window sliced from the full 200 body")
        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7], "Second window from the persisted file, not the body prefix")

        let ranged = await client.rangedSnapshot
        XCTAssertEqual(ranged.count, 1, "Only the first read hits the network; the rest are served from disk")
    }

    /// `download` mode always materializes to a temp file regardless of size.
    func testDownloadModeAlwaysUsesFile() async throws {
        let client = StubAttachmentClient(blob: blob)
        let ds = makeDataSource(client, maxInline: 0, mode: .download)
        let att = attachment(id: "a4", size: blob.count)

        let first = try await ds.attachmentData(att, range: 0..<4)
        XCTAssertEqual(Array(first), [0, 1, 2, 3])
        let second = try await ds.attachmentData(att, range: 4..<8)
        XCTAssertEqual(Array(second), [4, 5, 6, 7])

        let fileCalls = await client.fileSnapshot
        let ranged = await client.rangedSnapshot
        XCTAssertEqual(fileCalls, 1, "download mode downloads the whole body once")
        XCTAssertTrue(ranged.isEmpty, "download mode never issues ranged requests")
    }

    /// An empty (size 0) attachment returns empty cleanly.
    func testEmptyAttachmentReturnsEmpty() async throws {
        let client = StubAttachmentClient(blob: Data())
        let ds = makeDataSource(client, maxInline: 1024)
        let att = attachment(id: "a5", size: 0)

        let data = try await ds.attachmentData(att, range: nil)
        XCTAssertTrue(data.isEmpty)
    }

    /// A large attachment with a nil range returns the whole body. In `.range`
    /// mode a whole-body read streams to disk via `fileFetch` (not the in-memory
    /// `rangeFetch(nil)` path), then is sliced from the persisted file.
    func testLargeAttachmentWithNilRangeReturnsWholeBody() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a6", size: blob.count)

        let data = try await ds.attachmentData(att, range: nil)
        XCTAssertEqual(Array(data), Array(blob))
        let fileCalls = await client.fileSnapshot
        let ranged = await client.rangedSnapshot
        XCTAssertEqual(fileCalls, 1, "A whole-body read must stream to disk, not buffer in memory")
        XCTAssertTrue(ranged.isEmpty, "A whole-body read must not issue a ranged request")
    }

    /// An unknown-size (nil) attachment read with a nil range also streams to
    /// disk via `fileFetch` in `.range` mode rather than buffering in memory.
    func testUnknownSizeNilRangeStreamsToFile() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a10", size: -1) // size < 0 → unknown (nil)

        let data = try await ds.attachmentData(att, range: nil)
        XCTAssertEqual(Array(data), Array(blob))
        let fileCalls = await client.fileSnapshot
        let ranged = await client.rangedSnapshot
        XCTAssertEqual(fileCalls, 1, "Unknown-size whole-body read must stream to disk")
        XCTAssertTrue(ranged.isEmpty, "Unknown-size whole-body read must not issue a ranged request")
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
    /// request or materializing a temp file.
    func testReadAtEofReturnsEmptyWithoutRequest() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: true)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a8", size: blob.count) // size 10

        let data = try await ds.attachmentData(att, range: 10..<20)
        XCTAssertTrue(data.isEmpty)
        let ranged = await client.rangedSnapshot
        let fileCalls = await client.fileSnapshot
        XCTAssertTrue(ranged.isEmpty, "A read at EOF must not hit the network")
        XCTAssertEqual(fileCalls, 0, "A read at EOF must not materialize a temp file")
    }

    /// When the server ignores Range (200 full body), an over-long window is
    /// still sliced from the persisted file using the clamped bounds.
    func testRangeClampedWhenServerReturnsFullBody() async throws {
        let client = StubAttachmentClient(blob: blob, honorsRange: false)
        let ds = makeDataSource(client, maxInline: 4)
        let att = attachment(id: "a9", size: blob.count) // size 10

        let data = try await ds.attachmentData(att, range: 8..<20)
        XCTAssertEqual(Array(data), [8, 9], "200 fallback must slice with the clamped range")
    }

    /// A `clear()` that races an in-flight whole-body download must not leak the
    /// temp file the download produces afterwards. The owning fetch deletes its
    /// own result (it belongs to a cleared generation) and surfaces cancellation
    /// instead of re-populating the emptied cache.
    func testClearDuringDownloadDeletesLateTempFile() async throws {
        let cache = AttachmentByteCache(mode: .download, maxInlineBytes: 1024)
        let gate = Gate()
        let recorder = URLRecorder()

        // A fileFetch that ignores cancellation: it signals start, waits to be
        // released, then writes a real temp file and returns it regardless.
        let fileFetch: @Sendable () async throws -> URL = {
            await gate.signalStarted()
            await gate.waitForRelease()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data([1, 2, 3]).write(to: url, options: .atomic)
            await recorder.set(url)
            return url
        }
        let rangeFetch: @Sendable (Range<Int>?) async throws -> RangedDownload = { _ in
            RangedDownload(data: Data(), isPartial: false)
        }

        let readTask = Task<Data, Error> {
            try await cache.bytes(id: "x", size: 3, range: nil,
                                  rangeFetch: rangeFetch, fileFetch: fileFetch)
        }

        await gate.waitForStart()
        await cache.clear()
        await gate.release()

        do {
            _ = try await readTask.value
            XCTFail("A read whose download finished after clear() must not succeed")
        } catch is CancellationError {
            // Expected: the stale result is rejected.
        }

        let leaked = await recorder.url
        XCTAssertNotNil(leaked, "fileFetch should have produced a temp file")
        if let leaked {
            XCTAssertFalse(FileManager.default.fileExists(atPath: leaked.path),
                           "A temp file produced after clear() must be deleted, not leaked")
        }
    }
}

/// One-shot rendezvous so a test can block a `fileFetch` mid-flight, perform a
/// `clear()`, then release the fetch and observe the post-clear behavior.
private actor Gate {
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func signalStarted() {
        started = true
        startWaiter?.resume()
        startWaiter = nil
    }

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
}

/// Records the URL a `fileFetch` produced so the test can assert on its fate.
private actor URLRecorder {
    private(set) var url: URL?
    func set(_ value: URL) { url = value }
}
