import Foundation

/// Result of a (possibly ranged) attachment download.
///
/// `isPartial` distinguishes a genuine HTTP `206 Partial Content` response —
/// where `data` is exactly the requested window — from a `200 OK` response
/// where the server ignored the `Range` header and `data` is the **whole**
/// body. Callers use this to avoid mis-aligning a full body against a partial
/// offset (which would corrupt the served file).
public struct RangedDownload: Sendable {
    public let data: Data
    /// `true` when the server returned `206 Partial Content` (the `Range` was
    /// honored). `false` for a `200 OK` full body.
    public let isPartial: Bool

    public init(data: Data, isPartial: Bool) {
        self.data = data
        self.isPartial = isPartial
    }
}

/// Shared, product-agnostic helper that serves bounded byte windows of an
/// attachment to the FSKit `read(...)` path. Used by both the JIRA and
/// Confluence data sources so the caching/slicing logic lives in one place.
///
/// Two strategies, selectable per instance via ``Mode``:
///
/// - ``Mode/range``: stream only the requested window via an HTTP `Range`
///   request. If the server honors it (`206`), the window is returned directly
///   without buffering the whole file. If the server **ignores** `Range` and
///   returns the full body (`200`), the body is persisted to a local temp file
///   once and subsequent reads are served as slices from disk — so a
///   non-compliant server degrades gracefully instead of corrupting the file.
///   Small, known-size files (`size <= maxInlineBytes`) are downloaded once to
///   disk up-front to avoid issuing many ranged requests for repeated reads.
///
/// - ``Mode/download``: always download the whole body once to a local temp
///   file and serve slices from it. Independent of server `Range` support.
///
/// Both modes keep steady-state memory bounded to a single slice and never
/// fully buffer a multi-GB attachment in memory.
public actor AttachmentByteCache {
    public enum Mode: Sendable {
        /// Stream via HTTP `Range`, falling back to a disk copy on a `200` body.
        case range
        /// Always download the whole body to disk and slice locally.
        case download
    }

    /// The strategy used when a caller does not specify one. `range` preserves
    /// bandwidth on `Range`-capable servers while still being robust (the `200`
    /// fallback) on servers that ignore `Range`.
    public static let defaultMode: Mode = .range

    /// Fetches a (possibly ranged) window. A `nil` range requests the whole body.
    public typealias RangeFetch = @Sendable (_ range: Range<Int>?) async throws -> RangedDownload
    /// Streams the whole body to a temp file and returns its URL (caller owns it).
    public typealias FileFetch = @Sendable () async throws -> URL

    private let mode: Mode
    private let maxInlineBytes: Int

    /// Materialized whole-body temp files, keyed by attachment id (download mode
    /// or a `200` fallback in range mode).
    private var files: [String: URL] = [:]
    /// Single-flight guard so concurrent reads of the same attachment share one
    /// download.
    private var pendingFiles: [String: Task<URL, Error>] = [:]

    public init(mode: Mode = AttachmentByteCache.defaultMode,
                maxInlineBytes: Int = 16 * 1024 * 1024) {
        self.mode = mode
        self.maxInlineBytes = max(0, maxInlineBytes)
    }

    /// Serves the requested byte window for the attachment identified by `id`.
    ///
    /// - Parameters:
    ///   - id: Stable attachment identifier used as the cache key.
    ///   - size: Known total size in bytes, or `nil` if unknown.
    ///   - range: Requested window, or `nil` for the whole body.
    ///   - rangeFetch: Performs a (possibly ranged) HTTP download.
    ///   - fileFetch: Streams the whole body to a temp file.
    public func bytes(id: String, size: Int?, range: Range<Int>?,
                      rangeFetch: RangeFetch, fileFetch: @escaping FileFetch) async throws -> Data {
        // Clamp the requested window to the known size before doing any work, so
        // the issued HTTP `Range` never reaches past EOF (which stricter servers
        // reject with `416`) and disk slices stay in bounds. A `nil` size leaves
        // the range untouched (size unknown — rely on the server/disk to bound).
        let range = Self.clampedRange(range, size: size)
        // Start at/after EOF (or an empty/inverted window): nothing to serve, and
        // no network request needed.
        if let range, range.isEmpty { return Data() }
        // Already materialized to disk (download mode, or a prior 200 fallback).
        if let url = files[id], FileManager.default.fileExists(atPath: url.path) {
            return try Self.readSlice(at: url, range: range)
        }
        switch mode {
        case .download:
            let url = try await ensureFile(id: id, fileFetch: fileFetch)
            return try Self.readSlice(at: url, range: range)
        case .range:
            // Small, known-size files: download once to disk so repeated reads
            // do not each issue a ranged request.
            if let size, size >= 0, size <= maxInlineBytes {
                let url = try await ensureFile(id: id, fileFetch: fileFetch)
                return try Self.readSlice(at: url, range: range)
            }
            let result = try await rangeFetch(range)
            if result.isPartial {
                return result.data
            }
            // Server ignored Range and returned the whole body. Persist it once
            // so later reads are served from disk instead of re-downloading the
            // entire file, then return the requested slice.
            let url = try persistFullBody(id: id, data: result.data)
            return try Self.readSlice(at: url, range: range)
        }
    }

    /// Deletes all materialized temp files and cancels in-flight downloads.
    /// Called on `synchronize()` and unmount.
    public func clear() {
        for task in pendingFiles.values { task.cancel() }
        pendingFiles.removeAll()
        for url in files.values { try? FileManager.default.removeItem(at: url) }
        files.removeAll()
    }

    // MARK: - Private

    private func ensureFile(id: String, fileFetch: @escaping FileFetch) async throws -> URL {
        if let url = files[id], FileManager.default.fileExists(atPath: url.path) { return url }
        if let pending = pendingFiles[id] { return try await pending.value }
        let task = Task<URL, Error> { try await fileFetch() }
        pendingFiles[id] = task
        do {
            let url = try await task.value
            pendingFiles[id] = nil
            // A racing caller may have already stored a file; prefer the first.
            if let existing = files[id], existing != url {
                try? FileManager.default.removeItem(at: url)
                return existing
            }
            files[id] = url
            return url
        } catch {
            pendingFiles[id] = nil
            throw error
        }
    }

    private func persistFullBody(id: String, data: Data) throws -> URL {
        if let url = files[id], FileManager.default.fileExists(atPath: url.path) { return url }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .atomic)
        files[id] = url
        return url
    }

    /// Clamps a requested window to `[0, size)`. Returns `nil` unchanged (whole
    /// body). When `size` is `nil` the upper bound is left as requested. An
    /// at/after-EOF or inverted window collapses to an empty range (`lower..<lower`).
    private static func clampedRange(_ range: Range<Int>?, size: Int?) -> Range<Int>? {
        guard let range else { return nil }
        let lower = max(0, range.lowerBound)
        let cap = size.map { max(0, $0) } ?? range.upperBound
        let upper = min(range.upperBound, cap)
        guard lower < upper else { return lower..<lower }
        return lower..<upper
    }

    /// Reads a bounded slice from a local file via `FileHandle`, so only the
    /// requested window is held in memory. Reads past EOF return the available
    /// bytes; an empty or inverted range returns empty data.
    private static func readSlice(at url: URL, range: Range<Int>?) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let range else { return (try handle.readToEnd()) ?? Data() }
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound else { return Data() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return (try handle.read(upToCount: range.upperBound - range.lowerBound)) ?? Data()
    }
}
