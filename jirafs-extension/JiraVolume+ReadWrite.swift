#if canImport(FSKit)
import Foundation
import FSKit
import JiraAPI
import JiraFSCore

@available(macOS 15.4, *)
extension JiraVolume: FSVolume.ReadWriteOperations {
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, Error?) -> Void) {
        guard let node = item as? JiraFSItem else { reply(0, FSKitError.notFound); return }
        Task {
            do {
                try await self.loadPayload(for: node)
                guard let data = node.cachedData else {
                    reply(0, FSKitError.notFound); return
                }
                let start = Int(offset)
                guard start < data.count else { reply(0, nil); return }
                let end = min(data.count, start + length)
                let slice = data.subdata(in: start..<end)
                let copied = slice.withUnsafeBytes { src -> Int in
                    guard let baseAddress = src.baseAddress else { return 0 }
                    return buffer.withUnsafeMutableBytes { dst -> Int in
                        guard let dstBase = dst.baseAddress else { return 0 }
                        let n = min(dst.count, slice.count)
                        memcpy(dstBase, baseAddress, n)
                        return n
                    }
                }
                reply(copied, nil)
            } catch {
                reply(0, FSKitError.from(error))
            }
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, Error?) -> Void) {
        reply(0, FSKitError.readOnly)
    }
}
#endif
