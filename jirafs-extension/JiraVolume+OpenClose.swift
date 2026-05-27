import Foundation
import FSKit
import JiraAPI
import JiraFSCore

/// Parses a JIRA ISO 8601 date string (with or without fractional seconds).
/// JIRA Cloud/Server returns dates like "2023-01-15T10:30:00.000+0000".
private func parseJiraDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

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
        case .agentsGuide, .issuesAgentsGuide:
            guard let url = Bundle.main.url(forResource: "AGENTS", withExtension: "md"),
                  let fileData = try? Data(contentsOf: url)
            else {
                logger.error("loadPayload: AGENTS.md not found in bundle")
                return
            }
            data = fileData
        case .summary(let key):
            let issue = try await dataSource.issue(key: key)
            data = IssueFileBuilder.summary(issue)
            applyIssueTimes(issue, to: node)
        case .description(let key):
            let issue = try await dataSource.issue(key: key)
            data = IssueFileBuilder.description(issue)
            applyIssueTimes(issue, to: node)
        case .metadata(let key):
            let issue = try await dataSource.issue(key: key)
            data = IssueFileBuilder.metadata(issue)
            applyIssueTimes(issue, to: node)
        case .projectMeta(let key):
            data = IssueFileBuilder.projectMeta(try await dataSource.project(key: key))
        case .comment(let issueKey, let index):
            let comments = try await dataSource.comments(issueKey: issueKey)
            // Use the stable 1-based index stored in FSNodeKind — this is
            // immune to filename deduplication (“foo (2).md” etc.).
            guard index >= 1 && index <= comments.count else {
                throw JiraAPIError.notFound
            }
            let comment = comments[index - 1]
            data = IssueFileBuilder.commentBody(comment)
            if let mtime = parseJiraDate(comment.updated) { node.cachedMTime = mtime }
            node.cachedBirthTime = parseJiraDate(comment.created) ?? node.cachedMTime
        case .attachment(let issueKey, let attachmentId):
            let atts = try await dataSource.attachments(issueKey: issueKey)
            // Match by stable attachment id — immune to filename sanitization
            // and deduplication ("report (2).pdf" etc.).
            guard let attachment = atts.first(where: { $0.id == attachmentId }) else {
                throw JiraAPIError.notFound
            }
            data = try await dataSource.attachmentData(attachment)
            if let ts = parseJiraDate(attachment.created) {
                node.cachedMTime = ts
                node.cachedBirthTime = ts
            }
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
            applyIssueTimes(issue, to: node)
        case .metadataNeverIndex:
            // Zero-byte file — presence in the listing is all Spotlight checks for.
            data = Data()
        case .configFile:
            // Intentionally returns an empty JSON object rather than the real
            // config file contents.
            //
            // Rationale: /.jirafs/config.json is visible to any process that
            // can read the mount point. Exposing the actual config would leak
            // the JIRA instance URL, user email, allowedProjectKeys, etc.
            // Auth tokens/PATs are stored in Keychain (not in config.json),
            // so the risk is limited, but we keep this as an opaque placeholder
            // for now until a deliberate decision is made to expose the config.
            data = Data("{}\n".utf8)
        default:
            return
        }
        logger.info("loadPayload: loaded kind=\(String(describing: node.kind), privacy: .public) bytes=\(data.count)")
        node.cachedData = data
        node.cachedSize = UInt64(data.count)
    }

    /// Sets `cachedMTime` and `cachedBirthTime` on `node` from the issue's
    /// `updated` and `created` timestamps.
    private func applyIssueTimes(_ issue: JiraIssue, to node: JiraFSItem) {
        if let mtime = parseJiraDate(issue.fields.updated) { node.cachedMTime = mtime }
        node.cachedBirthTime = parseJiraDate(issue.fields.created) ?? node.cachedMTime
    }
}
