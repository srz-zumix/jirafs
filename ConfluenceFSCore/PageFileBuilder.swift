import Foundation
import AtlassianCore
import ConfluenceAPI

/// Builds the per-page file payloads (page.md, .metadata.json, .labels.txt,
/// comment files) from Confluence models.
public enum PageFileBuilder {

    /// `page.md` — the page body rendered to Markdown, prefixed with a
    /// `# title` heading. Attachment references are rewritten to point at the
    /// sibling `.attachments/{file}` directory on the mounted filesystem.
    public static func body(_ page: ConfluencePage, attachments: [ConfluenceAttachment] = []) -> Data {
        var out = "# \(page.title)\n\n"
        let md = ConfluenceContentRenderer.renderBody(page.body)
        out += rewriteAttachmentLinksMarkdown(md, attachments: attachments)
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

    /// `{Title}.html` — a minimal HTML document. For storage-format XHTML and
    /// server-rendered `view` HTML bodies the raw markup is embedded directly;
    /// otherwise the rendered Markdown is shown inside a `<pre>` block.
    /// Attachment references (images/links) are rewritten to point at the
    /// sibling `{Title}/.attachments/{file}` paths so the rendered HTML resolves
    /// against the mounted filesystem instead of server URLs.
    public static func html(_ page: ConfluencePage, attachments: [ConfluenceAttachment] = []) -> Data {
        let title = escapeHTML(page.title)
        let content: String
        if let body = page.body, body.format == .storage || body.format == .view {
            content = rewriteAttachmentLinks(body.value, pageTitle: page.title, attachments: attachments)
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

    /// Rewrites attachment image/link references in a page body so they resolve
    /// to the sibling `{Title}/.attachments/{file}` paths on the mounted
    /// filesystem instead of Confluence server URLs.
    ///
    /// Handles both representations:
    /// - **storage** XHTML — `<ac:image>…<ri:attachment ri:filename="X"/></ac:image>`
    ///   and `<ac:link><ri:attachment ri:filename="X"/>…</ac:link>` become
    ///   `<img>` / `<a>` tags pointing at the local path.
    /// - server-rendered **view** HTML — `<img src>` / `<a href>` URLs whose
    ///   trailing filename matches a known attachment are repointed locally.
    static func rewriteAttachmentLinks(
        _ body: String, pageTitle: String, attachments: [ConfluenceAttachment]
    ) -> String {
        let folder = FileNameSanitizer.sanitize(pageTitle)
        func localPath(for fileName: String) -> String {
            let safe = FileNameSanitizer.sanitize(fileName)
            return relativeURL("\(folder)/.attachments/\(safe)")
        }

        var result = body

        // storage: <ac:image …>…<ri:attachment ri:filename="X"/>…</ac:image>
        result = replaceAll(in: result, pattern: "<ac:image[^>]*>\\s*<ri:attachment[^>]*ri:filename=\"([^\"]+)\"[^>]*/?>\\s*(?:</ac:image>)?") { name in
            let alt = escapeAttr(name)
            return "<img src=\"\(localPath(for: name))\" alt=\"\(alt)\">"
        }

        // storage: <ac:link>…<ri:attachment ri:filename="X"/>…</ac:link>
        result = replaceAll(in: result, pattern: "<ac:link[^>]*>\\s*<ri:attachment[^>]*ri:filename=\"([^\"]+)\"[^>]*/?>\\s*</ac:link>") { name in
            "<a href=\"\(localPath(for: name))\">\(escapeHTML(name))</a>"
        }

        // view HTML: repoint src/href URLs ending in a known attachment file.
        for att in attachments {
            let safe = FileNameSanitizer.sanitize(att.title)
            let path = relativeURL("\(folder)/.attachments/\(safe)")
            for attr in ["src", "href"] {
                result = replaceAll(in: result, pattern: "\(attr)=\"[^\"]*?/\(escapeRegex(att.title))(\\?[^\"]*)?\"") { _ in
                    "\(attr)=\"\(path)\""
                }
            }
        }
        return result
    }

    private static func relativeURL(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    /// Rewrites attachment references in rendered Markdown so they resolve to the
    /// sibling `.attachments/{file}` directory: storage-format `attachments/X`
    /// targets become `.attachments/X`, and view/ADF image/link URLs whose
    /// trailing filename matches a known attachment are repointed locally.
    static func rewriteAttachmentLinksMarkdown(
        _ markdown: String, attachments: [ConfluenceAttachment]
    ) -> String {
        var result = markdown

        // storage renderer emits `](attachments/X)`; point it at `.attachments/`.
        result = replaceAll(in: result, pattern: "\\]\\(attachments/([^)]+)\\)") { name in
            "](.attachments/\(relativeURL(name)))"
        }

        // view/ADF Markdown URLs ending in a known attachment file → local path.
        for att in attachments {
            let path = relativeURL(".attachments/\(FileNameSanitizer.sanitize(att.title))")
            result = replaceAll(in: result, pattern: "\\]\\(([^)]*?/\(escapeRegex(att.title))(?:\\?[^)]*)?)\\)") { _ in
                "](\(path))"
            }
        }
        return result
    }

    private static func escapeAttr(_ s: String) -> String {
        escapeHTML(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeRegex(_ s: String) -> String {
        NSRegularExpression.escapedPattern(for: s)
    }

    /// Applies `transform` to capture group 1 of each match of `pattern`.
    private static func replaceAll(
        in s: String, pattern: String, transform: (String) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return s
        }
        let ns = s as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 2, m.range(at: 1).location != NSNotFound else { return }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(ns.substring(with: m.range(at: 1)))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func jsonOrNull<T>(_ value: T?) -> Any {
        guard let v = value else { return NSNull() }
        return v
    }
}
