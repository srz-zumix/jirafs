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

    /// `.metadata.json` for a whiteboard — structured whiteboard metadata.
    /// Whiteboard canvas content is not exposed by the Confluence REST API, so
    /// `webURL` is the way to open the board itself.
    public static func whiteboardMeta(_ whiteboard: ConfluenceWhiteboard) -> Data {
        let dict: [String: Any] = [
            "id": whiteboard.id,
            "title": whiteboard.title,
            "type": "whiteboard",
            "spaceId": jsonOrNull(whiteboard.spaceId),
            "parentId": jsonOrNull(whiteboard.parentId),
            "authorId": jsonOrNull(whiteboard.authorId),
            "createdAt": jsonOrNull(whiteboard.createdAt),
            "webURL": jsonOrNull(whiteboard.webURL),
        ]
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: dict, options: opts)) ?? Data()
    }

    /// `whiteboard.md` — the whiteboard canvas as rendered by Rovo MCP. The
    /// rendering is produced by a beta API and may vary between calls, so the
    /// provenance note is part of the file.
    public static func whiteboardBody(_ whiteboard: ConfluenceWhiteboard, content: String) -> Data {
        var out = "# \(whiteboard.title)\n\n"
        out += "> Rendered from the whiteboard canvas via the Atlassian Rovo MCP server (beta).\n"
        out += "> The Confluence REST API does not expose this content.\n\n"
        out += WhiteboardCanvasRenderer.render(content) ?? content
        if !out.hasSuffix("\n") { out += "\n" }
        return Data(out.utf8)
    }

    /// `whiteboard.json` — the Rovo MCP response verbatim, so that consumers can
    /// parse fields the Markdown rendering drops.
    public static func whiteboardRaw(content: String) -> Data {
        Data((content.hasSuffix("\n") ? content : content + "\n").utf8)
    }

    /// `whiteboard.svg` — an approximate drawing of the canvas. Falls back to a
    /// title-only image when the payload cannot be parsed.
    public static func whiteboardSVG(_ whiteboard: ConfluenceWhiteboard, content: String) -> Data {
        if let svg = WhiteboardSVGRenderer.render(content, title: whiteboard.title) {
            return Data(svg.utf8)
        }
        let title = whiteboard.title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 120" width="480" height="120">
            <title>\(title)</title>
            <rect width="480" height="120" fill="#ffffff"/>
            <text x="240" y="56" font-family="Helvetica, Arial, sans-serif" font-size="16" \
            fill="#172b4d" text-anchor="middle">\(title)</text>
            <text x="240" y="80" font-family="Helvetica, Arial, sans-serif" font-size="12" \
            fill="#626f86" text-anchor="middle">The canvas could not be drawn.</text>
            </svg>

            """.utf8)
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
    public static func html(_ page: ConfluencePage, folderName: String? = nil, attachments: [ConfluenceAttachment] = []) -> Data {
        let title = escapeHTML(page.title)
        let folder = folderName ?? FileNameSanitizer.sanitize(page.title)
        let content: String
        if let body = page.body, body.format == .storage || body.format == .view {
            content = rewriteAttachmentLinks(body.value, folder: folder, attachments: attachments)
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
    ///
    /// `folder` must be the page's deduplicated on-disk folder stem (the same
    /// name used for the sibling `{folder}/` directory), not merely the
    /// sanitized title, so collisions between pages that sanitize to the same
    /// title still resolve to the correct `.attachments/` sibling.
    static func rewriteAttachmentLinks(
        _ body: String, folder: String, attachments: [ConfluenceAttachment]
    ) -> String {
        let (ordered, byTitle) = dedupedAttachmentNames(attachments)
        func localPath(for fileName: String) -> String {
            // Prefer the deduplicated on-disk entry name so links resolve to the
            // exact `.attachments/` file even when two attachments sanitize to
            // the same name; fall back to a plain sanitize when the referenced
            // file isn't in the listing (e.g. attachments unavailable).
            let name = byTitle[fileName] ?? FileNameSanitizer.sanitize(fileName)
            return relativeURL("\(folder)/.attachments/\(name)")
        }

        var result = body

        // storage: <ac:image …>…<ri:attachment ri:filename="X"/>…</ac:image>.
        // Tolerate extra children (captions/params) and content around the
        // attachment inside the block; the tempered-dot tokens never cross the
        // element's own `</ac:image>`, so an `<ac:image>` without an
        // `<ri:attachment>` (e.g. an external `<ri:url>` image) is left untouched
        // instead of the match running forward into a later image. The trailing
        // `</ac:image>` stays optional to preserve rewriting of malformed,
        // unclosed blocks (matching the previous behavior).
        result = replaceAll(in: result, pattern: "<ac:image[^>]*>(?:(?!</ac:image>)[\\s\\S])*?<ri:attachment[^>]*ri:filename=\"([^\"]+)\"[^>]*/?>(?:(?:(?!</ac:image>)[\\s\\S])*?</ac:image>)?") { name in
            let alt = escapeAttr(name)
            return "<img src=\"\(localPath(for: name))\" alt=\"\(alt)\">"
        }

        // storage: <ac:link>…<ri:attachment ri:filename="X"/>…</ac:link>.
        // Tolerate a link body (e.g. `<ac:plain-text-link-body>`) between the
        // attachment tag and the closing `</ac:link>`; the tempered-dot tokens
        // keep the match within a single link element. When the link carries an
        // explicit `<ac:plain-text-link-body>` label, use it as the visible text
        // so user-authored link labels aren't replaced by the filename.
        result = replaceAllMatches(
            in: result,
            pattern: "<ac:link[^>]*>(?:(?!</ac:link>)[\\s\\S])*?<ri:attachment[^>]*ri:filename=\"([^\"]+)\"[^>]*/?>(?:(?!</ac:link>)[\\s\\S])*?</ac:link>"
        ) { m, ns in
            guard let name = group(m, 1, ns) else { return nil }
            let label = plainTextLinkBody(in: ns.substring(with: m.range)) ?? name
            return "<a href=\"\(localPath(for: name))\">\(escapeHTML(label))</a>"
        }

        // view HTML: repoint src/href URLs ending in a known attachment file.
        // Restricted to Confluence attachment/thumbnail download URLs
        // (`/download/attachments/` or `/download/thumbnails/`) so an external
        // URL that merely ends with the same filename is left untouched. A single
        // pass over the body captures the attribute and the URL's trailing
        // filename segment and resolves it against a precomputed lookup, instead
        // of scanning the whole body once per attachment × attribute. Skipped
        // entirely when no such URL is present.
        if containsDownloadURL(result) {
            let lookup = downloadFileNameLookup(ordered)
            result = replaceAllMatches(
                in: result,
                pattern: "(src|href)=\"[^\"?]*/download/(?:attachments|thumbnails)/(?:[^\"/?]+/)*([^\"/?]+)(?:\\?[^\"]*)?\""
            ) { m, ns in
                guard let attr = group(m, 1, ns), let file = group(m, 2, ns),
                      let name = lookup[file.lowercased()] else { return nil }
                return "\(attr)=\"\(relativeURL("\(folder)/.attachments/\(name)"))\""
            }
        }
        return result
    }

    private static func relativeURL(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    /// Whether a page body could reference attachments worth listing to rewrite.
    ///
    /// A cheap necessary-condition pre-check so the caller can skip the
    /// attachment listing (cache/network) entirely for pages that reference no
    /// attachment. Attachments only affect the built `page.md` / `{Title}.html`
    /// when the body references one:
    /// - **storage/view**: a `<ri:attachment>` tag (rendered to `](attachments/X)`
    ///   / rewritten to `<img>`/`<a>`) or a Confluence
    ///   `/download/(attachments|thumbnails)/` view URL.
    /// - **ADF (Cloud)**: a media node (`media`/`mediaSingle`/`mediaGroup`/
    ///   `mediaInline`), rendered to `](.attachments/…)`.
    /// If none are present, listing attachments cannot change the output.
    public static func bodyReferencesAttachments(_ body: ConfluenceBody?) -> Bool {
        guard let body, !body.value.isEmpty else { return false }
        let value = body.value
        switch body.format {
        case .atlasDocFormat:
            // ADF node types serialize as `"type":"media"` etc.; a `"media`
            // substring is a sound necessary condition (a false positive only
            // costs one cached listing).
            return value.range(of: "\"media", options: .caseInsensitive) != nil
        case .storage, .view:
            return value.range(of: "ri:attachment", options: .caseInsensitive) != nil
                || containsDownloadURL(value)
        }
    }

    /// Whether the Confluence attachment listing is needed to build `{Title}.html`
    /// for `body`. `html(...)` only rewrites attachment references for storage/view
    /// bodies; ADF (Cloud) bodies are rendered without consulting the listing, so
    /// the caller can skip fetching attachments for an ADF HTML body even when it
    /// contains media nodes. Storage/view bodies defer to
    /// `bodyReferencesAttachments`.
    public static func htmlReferencesAttachments(_ body: ConfluenceBody?) -> Bool {
        guard let body else { return false }
        switch body.format {
        case .storage, .view:
            return bodyReferencesAttachments(body)
        case .atlasDocFormat:
            return false
        }
    }

    /// Whether `s` contains a Confluence attachment/thumbnail download URL
    /// segment. A cheap necessary-condition pre-check (case-insensitive to match
    /// the rewrite regexes) so the per-attachment scan loop can be skipped when
    /// the body references no such URLs.
    private static func containsDownloadURL(_ s: String) -> Bool {
        s.range(of: "/download/attachments/", options: .caseInsensitive) != nil
            || s.range(of: "/download/thumbnails/", options: .caseInsensitive) != nil
    }

    /// Maps attachments to their deduplicated on-disk `.attachments/` entry
    /// names, replicating the volume's directory-listing logic
    /// (`deduplicate(sanitize(title))` in listing order) so rewritten links
    /// resolve to the exact file. Returns the ordered `(attachment, name)` pairs
    /// and a first-wins `title → name` lookup.
    private static func dedupedAttachmentNames(
        _ attachments: [ConfluenceAttachment]
    ) -> (ordered: [(att: ConfluenceAttachment, name: String)], byTitle: [String: String]) {
        var taken = Set<String>()
        var ordered: [(att: ConfluenceAttachment, name: String)] = []
        var byTitle: [String: String] = [:]
        for att in attachments {
            let name = FileNameSanitizer.deduplicate(FileNameSanitizer.sanitize(att.title), taken: &taken)
            ordered.append((att, name))
            if byTitle[att.title] == nil { byTitle[att.title] = name }
        }
        return (ordered, byTitle)
    }

    /// A filename in its percent-encoded URL-path form, encoding `/` (→ %2F)
    /// too: Confluence download URLs percent-encode path separators inside the
    /// filename segment, and `.urlPathAllowed` would otherwise leave `/` literal.
    private static func percentEncodedFileName(_ name: String) -> String {
        let pathSafe = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return name.addingPercentEncoding(withAllowedCharacters: pathSafe) ?? name
    }

    /// Maps the filename segment a Confluence download URL can end with — the
    /// attachment title verbatim or in its percent-encoded form — to the
    /// deduplicated on-disk `.attachments/` entry name. Lets the view/ADF URL
    /// rewrites resolve a captured URL filename in one lookup instead of scanning
    /// the whole body once per attachment. Keys are lowercased so lookups stay
    /// case-insensitive (matching the rewrite regexes' `.caseInsensitive`, e.g.
    /// `%2F` vs `%2f` or a URL filename cased differently than the title). First
    /// title wins on collisions, matching the previous ordered-loop behavior.
    private static func downloadFileNameLookup(
        _ ordered: [(att: ConfluenceAttachment, name: String)]
    ) -> [String: String] {
        var map: [String: String] = [:]
        for (att, name) in ordered {
            let title = att.title.lowercased()
            if map[title] == nil { map[title] = name }
            let encoded = percentEncodedFileName(att.title).lowercased()
            if map[encoded] == nil { map[encoded] = name }
        }
        return map
    }

    /// Rewrites attachment references in rendered Markdown so they resolve to the
    /// sibling `.attachments/{file}` directory: storage-format `attachments/X`
    /// targets become `.attachments/X`, and view/ADF image/link URLs whose
    /// trailing filename matches a known attachment are repointed locally.
    static func rewriteAttachmentLinksMarkdown(
        _ markdown: String, attachments: [ConfluenceAttachment]
    ) -> String {
        let (ordered, byTitle) = dedupedAttachmentNames(attachments)
        var result = markdown

        // ADF renderer (Cloud) emits media as `](.attachments/<alt>)` using the
        // raw media alt text (typically the original filename). Normalize it to
        // the deduplicated, sanitized, percent-encoded on-disk `.attachments/`
        // entry so alts containing `/`/`\` (sanitized to `_`), spaces (encoded),
        // or colliding with another attachment resolve to the right file. Runs
        // before the storage `](attachments/X)` rewrite below: the two markers
        // never coexist (a body uses one renderer), and the leading dot keeps the
        // patterns disjoint so storage output isn't re-encoded here.
        result = replaceAll(in: result, pattern: "\\]\\(\\.attachments/([^)]+)\\)") { name in
            let onDisk = byTitle[name] ?? FileNameSanitizer.sanitize(name)
            return "](.attachments/\(relativeURL(onDisk)))"
        }

        // storage renderer emits `](attachments/X)`; point it at the
        // deduplicated `.attachments/` entry (falling back to a plain sanitize
        // when the referenced file isn't in the listing).
        result = replaceAll(in: result, pattern: "\\]\\(attachments/([^)]+)\\)") { name in
            let onDisk = byTitle[name] ?? FileNameSanitizer.sanitize(name)
            return "](.attachments/\(relativeURL(onDisk)))"
        }

        // view/ADF Markdown URLs ending in a known attachment file → local path.
        // Restricted to Confluence attachment/thumbnail download URLs so external
        // URLs sharing an attachment's filename are left untouched. A single pass
        // captures the URL's trailing filename and resolves it against a
        // precomputed lookup, instead of scanning once per attachment. Skipped
        // when no such URL is present.
        if containsDownloadURL(result) {
            let lookup = downloadFileNameLookup(ordered)
            result = replaceAllMatches(
                in: result,
                pattern: "\\]\\([^)?]*/download/(?:attachments|thumbnails)/(?:[^)/?]+/)*([^)/?]+)(?:\\?[^)]*)?\\)"
            ) { m, ns in
                guard let file = group(m, 1, ns), let name = lookup[file.lowercased()] else { return nil }
                return "](\(relativeURL(".attachments/\(name)")))"
            }
        }
        return result
    }

    private static func escapeAttr(_ s: String) -> String {
        escapeHTML(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Replaces each full match of `pattern` with the result of applying
    /// `transform` to that match's capture group 1. The entire matched range is
    /// substituted (not just group 1); group 1 is merely the value passed to
    /// `transform`. Matches without a group-1 capture are left unchanged.
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

    /// Replaces each match of `pattern` with `transform(match)`, giving the
    /// closure access to all capture groups via the compiled result. Returning
    /// `nil` leaves that match unchanged (its text is preserved verbatim), so a
    /// single pass can decide per-match whether to rewrite. `group(_:_:)` reads a
    /// capture group's string (or `nil` when unmatched). Same regex options as
    /// `replaceAll`.
    private static func replaceAllMatches(
        in s: String, pattern: String,
        transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return s
        }
        let ns = s as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, let replacement = transform(m, ns) else { return }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += replacement
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// The string of capture group `i` in `m`, or `nil` when it didn't match.
    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String? {
        guard i < m.numberOfRanges else { return nil }
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    /// The visible text of an `<ac:plain-text-link-body>` (CDATA) inside a
    /// matched `<ac:link>` element, trimmed, or `nil` when absent/empty. This is
    /// where Confluence stores a custom label for an attachment link; preserving
    /// it keeps user-authored link text instead of substituting the filename.
    private static func plainTextLinkBody(in linkElement: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: "<ac:plain-text-link-body[^>]*>\\s*<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>\\s*</ac:plain-text-link-body>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = linkElement as NSString
        guard let m = re.firstMatch(in: linkElement, range: NSRange(location: 0, length: ns.length)),
              let text = group(m, 1, ns) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jsonOrNull<T>(_ value: T?) -> Any {
        guard let v = value else { return NSNull() }
        return v
    }
}
