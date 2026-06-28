import Foundation

/// Result of a (possibly ranged) attachment download.
///
/// `isPartial` distinguishes a genuine HTTP `206 Partial Content` response —
/// where `data` is exactly the requested window — from a `200 OK` response
/// where the server ignored the `Range` header and `data` is the **whole**
/// body. Callers use this to avoid mis-aligning a full body against a partial
/// offset (which would corrupt the served slice).
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
/// Strategy:
///
/// - Large (or unknown-size) attachments are streamed via bounded HTTP `Range`
///   requests and **not** cached, so the extension never buffers a multi-GB
///   file.
/// - Small attachments (`size <= maxInlineBytes`) are downloaded whole once and
///   cached **in memory**, then served as in-memory slices — so repeated reads
///   don't issue a ranged request per chunk.
/// - A server that ignores `Range` and returns a `200` full body has that body
///   cached in memory only when it fits under `maxInlineBytes`; otherwise the
///   requested slice is served and nothing is retained.
///
/// The in-memory cache is bounded by `maxTotalBytes` with LRU eviction. Nothing
/// is ever written to disk, so there is no plaintext-attachment-on-disk exposure
/// and no temp file to leak or clean up.
public actor AttachmentByteCache {
    /// Fetches a (possibly ranged) window. A `nil` range requests the whole body.
    public typealias RangeFetch = @Sendable (_ range: Range<Int>?) async throws -> RangedDownload

    /// Per-attachment cap: a whole body is cached only when it fits under this.
    private let maxInlineBytes: Int
    /// Total in-memory cache budget across all attachments (LRU-evicted).
    private let maxTotalBytes: Int

    /// Cached whole bodies, keyed by attachment id.
    private var cache: [String: Data] = [:]
    /// Attachment ids in least-recently-used order (oldest first).
    private var lru: [String] = []
    /// Running sum of `cache` value sizes, kept in step with inserts/evictions.
    private var totalBytes: Int = 0

    /// An in-flight whole-body download, tagged with a unique token so a
    /// completion only mutates its own entry (a `clear()` plus a fresh fetch can
    /// otherwise interleave).
    private struct PendingFetch {
        let token: UUID
        let task: Task<Data, Error>
    }
    /// Single-flight guard so concurrent whole-body fetches share one download.
    private var pending: [String: PendingFetch] = [:]
    /// Bumped by `clear()`. A fetch that started before the bump must not
    /// repopulate the just-invalidated cache.
    private var generation: Int = 0

    public init(maxInlineBytes: Int = 16 * 1024 * 1024, maxTotalBytes: Int? = nil) {
        let perEntry = max(0, maxInlineBytes)
        self.maxInlineBytes = perEntry
        // Default the total budget to a few max-size entries so alternating
        // reads of a handful of small attachments don't thrash the cache.
        self.maxTotalBytes = max(perEntry, maxTotalBytes ?? perEntry * 4)
    }

    /// Serves the requested byte window for the attachment identified by `id`.
    ///
    /// - Parameters:
    ///   - id: Stable attachment identifier used as the cache key.
    ///   - size: Known total size in bytes, or `nil` if unknown.
    ///   - range: Requested window, or `nil` for the whole body.
    ///   - rangeFetch: Performs a (possibly ranged) HTTP download.
    public func bytes(id: String, size: Int?, range: Range<Int>?,
                      rangeFetch: @escaping RangeFetch) async throws -> Data {
        // Clamp the requested window to the known size before doing any work, so
        // the issued HTTP `Range` never reaches past EOF (which stricter servers
        // reject with `416`) and slices stay in bounds. A `nil` size leaves the
        // range untouched (size unknown — rely on the server to bound it).
        let range = Self.clampedRange(range, size: size)
        // Start at/after EOF (or an empty/inverted window): nothing to serve, and
        // no network request needed.
        if let range, range.isEmpty { return Data() }
        // Already cached: slice from memory.
        if let data = cache[id] {
            touch(id)
            return Self.slice(data, range: range)
        }
        // Whole-body request, or a small known-size file: fetch the whole body
        // once and cache it (within the per-entry cap), then slice in memory.
        if range == nil || (size.map { $0 >= 0 && $0 <= maxInlineBytes } ?? false) {
            let data = try await fetchWholeBody(id: id, rangeFetch: rangeFetch)
            return Self.slice(data, range: range)
        }
        // Large/unknown-size bounded read: stream just the requested window.
        let startGeneration = generation
        let result = try await rangeFetch(range)
        if result.isPartial {
            return result.data
        }
        // Server ignored Range and returned the whole body. Cache it if it fits
        // (and the cache wasn't cleared meanwhile), then serve the slice.
        if generation == startGeneration {
            store(id: id, data: result.data)
        }
        return Self.slice(result.data, range: range)
    }

    /// Drops all cached bodies and cancels in-flight downloads. Called on
    /// `synchronize()` and unmount. Synchronous and fast (no disk, no network).
    public func clear() {
        generation &+= 1
        for pending in pending.values { pending.task.cancel() }
        pending.removeAll()
        cache.removeAll()
        lru.removeAll()
        totalBytes = 0
    }

    // MARK: - Private

    private func fetchWholeBody(id: String, rangeFetch: @escaping RangeFetch) async throws -> Data {
        if let data = cache[id] { touch(id); return data }
        if let pending = pending[id] {
            // Share an in-flight download. The owning fetch decides whether to
            // cache; this waiter just returns the bytes for its read.
            return try await pending.task.value
        }
        let token = UUID()
        let startGeneration = generation
        let task = Task<Data, Error> { try await rangeFetch(nil).data }
        pending[id] = PendingFetch(token: token, task: task)
        do {
            let data = try await task.value
            if pending[id]?.token == token { pending[id] = nil }
            // Only cache if the cache wasn't cleared while the fetch was in
            // flight; the in-memory body is still returned to the caller.
            if generation == startGeneration {
                store(id: id, data: data)
            }
            return data
        } catch {
            if pending[id]?.token == token { pending[id] = nil }
            throw error
        }
    }

    /// Caches a whole body (when it fits the per-entry cap), evicting LRU
    /// entries to honor the total budget.
    private func store(id: String, data: Data) {
        guard maxInlineBytes > 0, data.count <= maxInlineBytes else { return }
        if let existing = cache[id] {
            totalBytes -= existing.count
            lru.removeAll { $0 == id }
        }
        cache[id] = data
        totalBytes += data.count
        lru.append(id)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while totalBytes > maxTotalBytes, let oldest = lru.first {
            lru.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                totalBytes -= removed.count
            }
        }
    }

    /// Marks `id` as most-recently-used.
    private func touch(_ id: String) {
        guard let idx = lru.firstIndex(of: id) else { return }
        lru.remove(at: idx)
        lru.append(id)
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

    /// Returns the requested in-memory slice. A `nil` range returns the whole
    /// body; reads past EOF return the available bytes; an empty or inverted
    /// range returns empty data.
    private static func slice(_ data: Data, range: Range<Int>?) -> Data {
        guard let range else { return data }
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.lowerBound < data.count else { return Data() }
        let upper = min(range.upperBound, data.count)
        return data.subdata(in: range.lowerBound..<upper)
    }
}
