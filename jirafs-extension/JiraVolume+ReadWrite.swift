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
        Task {
            do {
                try await self.loadPayload(for: node)
                guard let data = node.cachedData else {
                    logger.warning("read: cachedData nil for \(String(describing: node.kind), privacy: .public)")
                    r.value(0, FSKitError.notFound); return
                }
                let start = Int(offset)
                logger.info("read: data.count=\(data.count) start=\(start) length=\(length)")
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
                logger.info("read: copied=\(copied)")
                r.value(copied, nil)
            } catch {
                logger.error("read: error=\(error, privacy: .public)")
                r.value(0, FSKitError.from(error))
            }
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, Error?) -> Void) {
        reply(0, FSKitError.readOnly)
    }
}
