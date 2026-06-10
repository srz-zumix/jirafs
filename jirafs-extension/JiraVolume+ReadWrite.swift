import Foundation
import FSKit
import JiraAPI
import JiraFSCore

extension FSMutableFileDataBuffer: @retroactive @unchecked Sendable {}

@available(macOS 15.4, *)
extension JiraVolume: FSVolume.ReadWriteOperations {
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, Error?) -> Void) {
        guard let node = item as? JiraFSItem else { reply(0, FSKitError.notFound); return }
        logger.info("read: kind=\(String(describing: node.kind), privacy: .public) offset=\(offset) length=\(length) bufLen=\(buffer.length)")
        let r = SendableBox(reply)
        let b = SendableBox(buffer)
        makeTask {
            do {
                // Attachments are streamed lazily via bounded Range requests so
                // that a multi-GB file is never fully buffered in memory. Take
                // this fast-path before `loadPayload` to avoid a redundant
                // attachment-list fetch (readAttachment fetches it itself).
                if case .attachment(let issueKey, let attachmentId) = node.kind {
                    try await self.readAttachment(issueKey: issueKey, attachmentId: attachmentId,
                                                  offset: offset, length: length,
                                                  buffer: b, reply: r)
                    return
                }
                try await self.loadPayload(for: node)
                guard let data = node.cachedData else {
                    self.logger.warning("read: cachedData nil for \(String(describing: node.kind), privacy: .public)")
                    r.value(0, FSKitError.notFound); return
                }
                guard offset >= 0 else { r.value(0, nil); return }
                let start = Int(offset)
                self.logger.info("read: data.count=\(data.count) start=\(start) length=\(length)")
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
                self.logger.info("read: copied=\(copied)")
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
        issueKey: String, attachmentId: String,
        offset: off_t, length: Int,
        buffer b: SendableBox<FSMutableFileDataBuffer>, reply r: SendableBox<(Int, Error?) -> Void>
    ) async throws {
        guard length > 0, let start = Int(exactly: offset), start >= 0 else { r.value(0, nil); return }
        let atts = try await dataSource.attachments(issueKey: issueKey)
        guard let attachment = atts.first(where: { $0.id == attachmentId }) else {
            r.value(0, FSKitError.notFound); return
        }
        // JIRA always reports an exact size; treat it as authoritative and clamp
        // the requested window to it. An empty (size 0) attachment yields EOF
        // without issuing any network request.
        let total = max(0, attachment.size)
        if start >= total { r.value(0, nil); return }
        // `want <= total - start`, so `start + want` never overflows.
        let want = min(length, total - start)
        guard want > 0 else { r.value(0, nil); return }
        let chunk = try await dataSource.attachmentData(attachment, range: start..<(start + want))
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
