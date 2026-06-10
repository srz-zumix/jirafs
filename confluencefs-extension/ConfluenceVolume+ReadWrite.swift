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
                try await self.loadPayload(for: node)
                // Attachments are streamed lazily via bounded Range requests so
                // that a multi-GB file is never fully buffered in memory.
                if case .attachment(_, let pageId, let attachmentId) = node.kind {
                    try await self.readAttachment(pageId: pageId, attachmentId: attachmentId,
                                                  node: node, offset: offset, length: length,
                                                  buffer: b, reply: r)
                    return
                }
                guard let data = node.cachedData else {
                    r.value(0, FSKitError.notFound); return
                }
                guard offset >= 0 else { r.value(0, nil); return }
                let start = Int(offset)
                guard start < data.count else { r.value(0, nil); return }
                let end = min(data.count, start + length)
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

    /// Serves a bounded byte window of an attachment without buffering the whole
    /// file. The data source decides whether to cache (small files) or stream
    /// the requested Range (large/unknown-size files).
    private func readAttachment(
        pageId: String, attachmentId: String, node: ConfluenceFSItem,
        offset: off_t, length: Int,
        buffer b: SendableBox<FSMutableFileDataBuffer>, reply r: SendableBox<(Int, Error?) -> Void>
    ) async throws {
        guard offset >= 0, length > 0 else { r.value(0, nil); return }
        let atts = try await dataSource.attachments(pageId: pageId)
        guard let attachment = atts.first(where: { $0.id == attachmentId }) else {
            r.value(0, FSKitError.notFound); return
        }
        let start = Int(offset)
        let total = Int(node.cachedSize)
        // Clamp the window to the known size when available; an unknown size
        // (total == 0) relies on the server to bound the response.
        if total > 0 && start >= total { r.value(0, nil); return }
        let end = total > 0 ? min(total, start + length) : start + length
        guard end > start else { r.value(0, nil); return }
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
