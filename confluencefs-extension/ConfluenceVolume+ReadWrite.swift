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

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, Error?) -> Void) {
        reply(0, FSKitError.readOnly)
    }
}
