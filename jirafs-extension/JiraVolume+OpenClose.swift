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
        makeTask {
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
            // Drop cached payload on final close so the next open always
            // fetches fresh data from IssueDataSource (stale-while-revalidate
            // may have served outdated content on the first open, and
            // node.cachedData would otherwise pin that stale HTML/text
            // indefinitely while the background refresh already completed).
            node.cachedData = nil
            node.cachedSize = 0
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
        case .comment(let issueKey, let index):
            let comments = try await dataSource.comments(issueKey: issueKey)
            // Use the stable 1-based index stored in FSNodeKind — this is
            // immune to filename deduplication (“foo (2).md” etc.).
            guard index >= 1 && index <= comments.count else {
                throw JiraAPIError.notFound
            }
            data = IssueFileBuilder.commentBody(comments[index - 1])
        case .attachment(let issueKey, let attachmentId):
            let atts = try await dataSource.attachments(issueKey: issueKey)
            // Match by stable attachment id — immune to filename sanitization
            // and deduplication ("report (2).pdf" etc.).
            guard let attachment = atts.first(where: { $0.id == attachmentId }) else {
                throw JiraAPIError.notFound
            }
            data = try await dataSource.attachmentData(attachment)
        case .issueHtml(let key):
            async let issueResult    = dataSource.issue(key: key)
            async let commentsResult = dataSource.comments(issueKey: key)
            async let attsResult     = dataSource.attachments(issueKey: key)
            async let fieldNamesResult = dataSource.fieldNames()
            let issue      = try await issueResult
            let comments   = (try? await commentsResult) ?? []
            let atts       = (try? await attsResult) ?? []
            let fieldNames = await fieldNamesResult
            let baseURL    = await dataSource.client.config.baseURL
            data = IssueFileBuilder.html(issue, comments: comments, attachments: atts, baseURL: baseURL, fieldNames: fieldNames)
        case .metadataNeverIndex:
            // Zero-byte file — presence in the listing is all Spotlight checks for.
            data = Data()
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
