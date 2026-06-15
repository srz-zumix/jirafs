import Foundation
import AtlassianCore
import ConfluenceAPI

/// Builds the per-page file payloads (page.md, .metadata.json, .labels.txt,
/// comment files) from Confluence models.
public enum PageFileBuilder {

    /// `page.md` — the page body rendered to Markdown, prefixed with a
    /// `# title` heading.
    public static func body(_ page: ConfluencePage) -> Data {
        var out = "# \(page.title)\n\n"
        let md = ConfluenceContentRenderer.renderBody(page.body)
        out += md
        if !out.hasSuffix("\n") { out += "\n" }
        return Data(out.utf8)
    }

    /// `.metadata.json` — structured page metadata.
    public static func metadata(_ page: ConfluencePage) -> Data {
        var dict: [String: Any] = [
            "id": page.id,
            "title": page.title,
            "spaceId": jsonOrNull(page.spaceId),
            "parentId": jsonOrNull(page.parentId),
            "version": jsonOrNull(page.version),
            "authorId": jsonOrNull(page.authorId),
            "createdAt": jsonOrNull(page.createdAt),
            "webURL": jsonOrNull(page.webURL),
        ]
        if let format = page.body?.format {
            dict["bodyFormat"] = format.rawValue
        }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: dict, options: opts)) ?? Data()
    }

    /// `labels.txt` — one label per line (prefix-qualified when present).
    public static func labels(_ labels: [ConfluenceLabel]) -> Data {
        let lines = labels.map { label -> String in
            if let prefix = label.prefix, !prefix.isEmpty {
                return "\(prefix):\(label.name)"
            }
            return label.name
        }
        return Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
    }

    /// A single comment file in Markdown.
    public static func comment(_ comment: ConfluenceComment) -> Data {
        let author = comment.authorLabel ?? "unknown"
        let created = comment.createdAt ?? ""
        var out = "**\(author)**"
        if !created.isEmpty { out += " — \(created)" }
        out += "\n\n"
        out += ConfluenceContentRenderer.renderBody(comment.body)
        if !out.hasSuffix("\n") { out += "\n" }
        return Data(out.utf8)
    }

    /// File name for a comment: `NNN_author_date.md` (1-based index, zero-padded).
    public static func commentFileName(index: Int, comment: ConfluenceComment) -> String {
        let n = String(format: "%03d", index)
        let author = FileNameSanitizer.sanitize(comment.authorLabel ?? "unknown")
        // Sanitize the date too: it is server-supplied and a malicious instance
        // could return a value containing path separators, so it must not be
        // trusted as a raw filename component.
        let rawDate = String((comment.createdAt ?? "").prefix(10))
        let date = rawDate.isEmpty ? "" : FileNameSanitizer.sanitize(rawDate)
        let stem = date.isEmpty ? "\(n)_\(author)" : "\(n)_\(author)_\(date)"
        return "\(stem).md"
    }

    /// `.space.json` — space metadata.
    public static func spaceMeta(_ space: ConfluenceSpace) -> Data {
        let dict: [String: Any] = [
            "id": space.id,
            "key": space.key,
            "name": space.name,
            "type": jsonOrNull(space.type),
            "homepageId": jsonOrNull(space.homepageId),
        ]
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: dict, options: opts)) ?? Data()
    }

    /// `{Title}.html` — a minimal HTML document. For storage-format bodies the
    /// raw XHTML is embedded directly; otherwise the rendered Markdown is shown
    /// inside a `<pre>` block.
    public static func html(_ page: ConfluencePage) -> Data {
        let title = escapeHTML(page.title)
        let content: String
        if let body = page.body, body.format == .storage {
            content = body.value
        } else {
            let md = ConfluenceContentRenderer.renderBody(page.body)
            content = "<pre>\(escapeHTML(md))</pre>"
        }
        let doc = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(title)</title>
        </head>
        <body>
        <h1>\(title)</h1>
        \(content)
        </body>
        </html>

        """
        return Data(doc.utf8)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func jsonOrNull<T>(_ value: T?) -> Any {
        guard let v = value else { return NSNull() }
        return v
    }
}
