import Foundation
import FSKit
import AtlassianCore
import ConfluenceAPI
import ConfluenceFSCore

extension FSMutableFileDataBuffer: @retroactive @unchecked Sendable {}

@available(macOS 15.4, *)
extension ConfluenceVolume: FSVolume.ReadWriteOperations {
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, Error?) -> Void) {
        guard let node = item as? ConfluenceFSItem else { reply(0, FSKitError.notFound); return }
        let r = SendableBox(reply)
        let b = SendableBox(buffer)
        makeTask {
            do {
                // Attachments are streamed lazily via bounded Range requests so
                // that a multi-GB file is never fully buffered in memory. Take
                // this fast-path before `loadPayload` to avoid a redundant
                // attachment-list fetch (readAttachment fetches it itself).
                if case .attachment(_, let pageId, let attachmentId) = node.kind {
                    try await self.readAttachment(pageId: pageId, attachmentId: attachmentId,
                                                  node: node, offset: offset, length: length,
                                                  buffer: b, reply: r)
                    return
                }
                try await self.loadPayload(for: node)
                guard let data = node.cachedData else {
                    r.value(0, FSKitError.notFound); return
                }
                guard offset >= 0, length > 0 else { r.value(0, nil); return }
                let start = Int(offset)
                guard start < data.count else { r.value(0, nil); return }
                // Guard the addition: a near-Int.max `length` would overflow and
                // make `min(...)` yield a negative end, crashing `subdata`.
                let (rawEnd, overflow) = start.addingReportingOverflow(length)
                let end = overflow ? data.count : min(data.count, rawEnd)
                let slice = data.subdata(in: start..<end)
                let copied = slice.withUnsafeBytes { src -> Int in
                    guard let baseAddress = src.baseAddress else { return 0 }
                    return b.value.withUnsafeMutableBytes { dst -> Int in
                        guard let dstBase = dst.baseAddress else { return 0 }
                        let n = min(dst.count, slice.count)
                        memcpy(dstBase, baseAddress, n)
                        return n
                    }
                }
                r.value(copied, nil)
            } catch {
                self.logger.error("read: error=\(error, privacy: .public)")
                r.value(0, FSKitError.from(error))
            }
        }
    }

    /// Serves a bounded byte window of an attachment. The data source downloads
    /// the body once to a local temp file and serves slices from it, so only the
    /// requested window is held in memory and serving does not depend on the
    /// server honoring HTTP `Range` requests.
    private func readAttachment(
        pageId: String, attachmentId: String, node: ConfluenceFSItem,
        offset: off_t, length: Int,
        buffer b: SendableBox<FSMutableFileDataBuffer>, reply r: SendableBox<(Int, Error?) -> Void>
    ) async throws {
        guard length > 0, let start = Int(exactly: offset), start >= 0 else { r.value(0, nil); return }
        let atts = try await dataSource.attachments(pageId: pageId)
        guard let attachment = atts.first(where: { $0.id == attachmentId }) else {
            r.value(0, FSKitError.notFound); return
        }
        // Request exactly the asked window. The data source clamps to the file's
        // real size (reads past EOF return the available bytes), so no separate
        // total-size bookkeeping is needed here.
        let (sum, overflow) = start.addingReportingOverflow(length)
        let end = overflow ? Int.max : sum
        let chunk = try await dataSource.downloadAttachment(attachment, range: start..<end)
        let copied = chunk.withUnsafeBytes { src -> Int in
            guard let baseAddress = src.baseAddress else { return 0 }
            return b.value.withUnsafeMutableBytes { dst -> Int in
                guard let dstBase = dst.baseAddress else { return 0 }
                let n = min(dst.count, chunk.count)
                memcpy(dstBase, baseAddress, n)
                return n
            }
        }
        r.value(copied, nil)
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, Error?) -> Void) {
        reply(0, FSKitError.readOnly)
    }
}
