import Foundation
import FSKit
import AtlassianCore
import ConfluenceAPI
import ConfluenceFSCore

/// Parses an ISO 8601 date string (with or without fractional seconds).
private func parseConfluenceDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

@available(macOS 15.4, *)
extension ConfluenceVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        guard let node = item as? ConfluenceFSItem else { reply(FSKitError.notFound); return }
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
        if let node = item as? ConfluenceFSItem, modes.isEmpty {
            node.cachedData = nil
            node.cachedSize = 0
        }
        reply(nil)
    }

    /// Populate `cachedData` for the node by querying the data source.
    func loadPayload(for node: ConfluenceFSItem) async throws {
        if node.cachedData != nil { return }
        let data: Data
        switch node.kind {
        case .agentsGuide:
            guard let url = Bundle.main.url(forResource: "AGENTS", withExtension: "md"),
                  let fileData = try? Data(contentsOf: url)
            else {
                logger.error("loadPayload: AGENTS.md not found in bundle")
                return
            }
            data = fileData
        case .metadataNeverIndex:
            data = Data()
        case .configFile:
            data = Data("{}\n".utf8)
        case .spaceMeta(let key):
            guard let space = try await dataSource.space(key: key) else {
                throw AtlassianError.notFound
            }
            data = PageFileBuilder.spaceMeta(space)
        case .pageBody(_, let pageId):
            let page = try await dataSource.page(id: pageId)
            data = PageFileBuilder.body(page)
            applyPageTimes(page, to: node)
        case .pageMeta(_, let pageId):
            let page = try await dataSource.page(id: pageId)
            data = PageFileBuilder.metadata(page)
            applyPageTimes(page, to: node)
        case .pageHtml(_, let pageId):
            let page = try await dataSource.page(id: pageId)
            data = PageFileBuilder.html(page)
            applyPageTimes(page, to: node)
        case .labels(_, let pageId):
            let labels = try await dataSource.labels(pageId: pageId)
            data = PageFileBuilder.labels(labels)
        case .comment(_, let pageId, let index):
            let comments = try await dataSource.comments(pageId: pageId)
            guard index >= 1 && index <= comments.count else {
                throw AtlassianError.notFound
            }
            let comment = comments[index - 1]
            data = PageFileBuilder.comment(comment)
            if let ts = parseConfluenceDate(comment.createdAt) {
                node.cachedMTime = ts
                node.cachedBirthTime = ts
            }
        case .attachment(_, let pageId, let attachmentId):
            let atts = try await dataSource.attachments(pageId: pageId)
            guard let attachment = atts.first(where: { $0.id == attachmentId }) else {
                throw AtlassianError.notFound
            }
            // Do NOT download the attachment bytes here. The file size comes
            // from listing metadata, and the byte content is served lazily by
            // `read(...)` via bounded Range requests so that a multi-GB
            // attachment is never fully buffered in memory. When the listing
            // omits `fileSize`, probe the size with a HEAD request: the kernel
            // never issues `read(...)` for a file reported as 0 bytes, so an
            // unknown-size attachment would otherwise be unreadable. A genuine
            // probe failure (auth/network/server) is propagated so the open
            // fails with a real error instead of silently appearing empty; only
            // an undeterminable size (probe returns nil, e.g. no Content-Length)
            // falls back to 0.
            let size: Int
            if let known = attachment.fileSize {
                size = max(0, known)
            } else {
                size = try await dataSource.attachmentSize(attachment) ?? 0
            }
            node.cachedSize = UInt64(size)
            return
        default:
            return
        }
        node.cachedData = data
        node.cachedSize = UInt64(data.count)
    }

    private func applyPageTimes(_ page: ConfluencePage, to node: ConfluenceFSItem) {
        guard let created = parseConfluenceDate(page.createdAt) else { return }
        node.cachedBirthTime = created
        // Confluence's domain model exposes the page *creation* time but not a
        // distinct "last modified" timestamp; both Cloud (`version.number`) and
        // DC (`version.number`) increment `version` on every edit, though. Fold
        // it into the modification time so each edit advances `mtime` by one
        // second past the creation time. Without this, `mtime` never changes on
        // edit, and mtime-based cache consumers — notably a browser or QuickLook
        // viewing `{Title}.html` — keep serving the stale rendered file even
        // though the underlying page body was updated. (`cat page.md` re-reads
        // each time and so refreshes regardless, which is why only the HTML
        // sibling appeared stale.)
        let versionOffset = TimeInterval(max(0, page.version ?? 0))
        node.cachedMTime = created.addingTimeInterval(versionOffset)
    }
}
