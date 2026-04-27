#if canImport(FSKit)
import Foundation
import FSKit
import JiraAPI
import JiraFSCore

@available(macOS 15.4, *)
extension JiraVolume: FSVolume.OpenCloseOperations {
    func open(_ item: FSItem, withMode mode: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        guard let node = item as? JiraFSItem else { reply(FSKitError.notFound); return }
        if mode.contains(.write) {
            reply(FSKitError.readOnly); return
        }
        Task {
            do {
                try await self.loadPayload(for: node)
                reply(nil)
            } catch {
                reply(FSKitError.from(error))
            }
        }
    }

    func close(_ item: FSItem, keepAlive: Bool, replyHandler reply: @escaping (Error?) -> Void) {
        if let node = item as? JiraFSItem, !keepAlive {
            // Drop binary payload but keep metadata if cheap to keep.
            switch node.kind {
            case .attachment:
                node.cachedData = nil
                node.cachedSize = 0
            default:
                break
            }
        }
        reply(nil)
    }

    /// Populate `cachedData` for the node by querying the data source.
    func loadPayload(for node: JiraFSItem) async throws {
        if node.cachedData != nil { return }
        let data: Data
        switch node.kind {
        case .summary(let key):
            data = IssueFileBuilder.summary(try await dataSource.issue(key: key))
        case .description(let key):
            data = IssueFileBuilder.description(try await dataSource.issue(key: key))
        case .metadata(let key):
            data = IssueFileBuilder.metadata(try await dataSource.issue(key: key))
        case .projectMeta(let key):
            data = IssueFileBuilder.projectMeta(try await dataSource.project(key: key))
        case .comment(let issueKey, let fileName):
            let comments = try await dataSource.comments(issueKey: issueKey)
            guard let (idx, comment) = comments.enumerated().first(where: {
                IssueFileBuilder.commentFileName(index: $0 + 1, comment: $1) == fileName
            }) else {
                throw JiraAPIError.notFound
            }
            _ = idx
            data = IssueFileBuilder.commentBody(comment)
        case .attachment(let issueKey, let fileName):
            let atts = try await dataSource.attachments(issueKey: issueKey)
            guard let attachment = atts.first(where: { FileNameSanitizer.sanitize($0.filename) == fileName }) else {
                throw JiraAPIError.notFound
            }
            data = try await dataSource.attachmentData(attachment)
        case .configFile:
            data = Data("{}\n".utf8)
        default:
            return
        }
        node.cachedData = data
        node.cachedSize = UInt64(data.count)
    }
}
#endif
