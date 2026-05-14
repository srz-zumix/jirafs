import Foundation
import FSKit
import JiraAPI
import JiraFSCore

@available(macOS 15.4, *)
extension JiraVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        guard let node = item as? JiraFSItem else { reply(FSKitError.notFound); return }
        if modes.contains(.write) {
            reply(FSKitError.readOnly); return
        }
        let r = SendableBox(reply)
        Task {
            do {
                try await self.loadPayload(for: node)
                r.value(nil)
            } catch {
                r.value(FSKitError.from(error))
            }
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        if let node = item as? JiraFSItem, modes.isEmpty {
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
        if node.cachedData != nil {
            logger.info("loadPayload: already cached kind=\(String(describing: node.kind), privacy: .public) size=\(node.cachedSize)")
            return
        }
        logger.info("loadPayload: fetching kind=\(String(describing: node.kind), privacy: .public)")
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
        logger.info("loadPayload: loaded kind=\(String(describing: node.kind), privacy: .public) bytes=\(data.count)")
        node.cachedData = data
        node.cachedSize = UInt64(data.count)
    }
}
