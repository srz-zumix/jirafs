import Foundation
import JiraAPI

/// Builds the various per-issue file payloads (summary.txt, metadata.json,
/// comment files) from `JiraIssue` / `JiraComment` models.
public enum IssueFileBuilder {

    public static func summary(_ issue: JiraIssue) -> Data {
        let s = issue.fields.summary ?? ""
        return Data((s + "\n").utf8)
    }

    public static func description(_ issue: JiraIssue) -> Data {
        let md = ContentRenderer.renderDescription(issue.fields.description)
        return Data((md + (md.hasSuffix("\n") ? "" : "\n")).utf8)
    }

    public static func metadata(_ issue: JiraIssue) -> Data {
        let assignee = issue.fields.assignee
        let reporter = issue.fields.reporter
        var dict: [String: Any] = [
            "key": issue.key,
            "id": issue.id,
            "type": issue.fields.issueType?.name as Any? ?? NSNull(),
            "status": issue.fields.status?.name as Any? ?? NSNull(),
            "priority": issue.fields.priority?.name as Any? ?? NSNull(),
            "labels": issue.fields.labels ?? [],
            "components": (issue.fields.components ?? []).compactMap { $0.name },
            "created": issue.fields.created as Any? ?? NSNull(),
            "updated": issue.fields.updated as Any? ?? NSNull(),
            "resolution": issue.fields.resolution?.name as Any? ?? NSNull(),
            "parent": issue.fields.parent?.key as Any? ?? NSNull(),
            "subtasks": (issue.fields.subtasks ?? []).compactMap { $0.key },
        ]
        if let a = assignee {
            dict["assignee"] = [
                "displayName": a.displayName as Any? ?? NSNull(),
                "emailAddress": a.emailAddress as Any? ?? NSNull(),
            ]
        } else {
            dict["assignee"] = NSNull()
        }
        if let r = reporter {
            dict["reporter"] = [
                "displayName": r.displayName as Any? ?? NSNull(),
                "emailAddress": r.emailAddress as Any? ?? NSNull(),
            ]
        } else {
            dict["reporter"] = NSNull()
        }
        if let links = issue.fields.issuelinks {
            dict["links"] = links.map { link -> [String: Any] in
                let direction = link.outwardIssue != nil ? "outward" : "inward"
                let other = link.outwardIssue ?? link.inwardIssue
                return [
                    "type": link.type.name as Any? ?? NSNull(),
                    "direction": direction,
                    "key": other?.key as Any? ?? NSNull(),
                ]
            }
        }
        // Custom fields — output as a nested object keyed by customfield_NNNNN.
        if !issue.fields.customFields.isEmpty {
            var custom: [String: Any] = [:]
            for (k, v) in issue.fields.customFields {
                custom[k] = jsonValueToAny(v)
            }
            dict["customFields"] = custom
        }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: dict, options: opts)) ?? Data()
    }

    private static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .null:              return NSNull()
        case .bool(let v):       return v
        case .number(let v):     return v
        case .string(let v):     return v
        case .array(let v):      return v.map { jsonValueToAny($0) }
        case .object(let v):     return v.mapValues { jsonValueToAny($0) }
        }
    }

    public static func commentBody(_ comment: JiraComment) -> Data {
        let author = comment.author?.displayName ?? "unknown"
        let email = comment.author?.emailAddress ?? ""
        let created = comment.created ?? ""
        let updated = comment.updated ?? ""
        let body = ContentRenderer.renderDescription(comment.body)
        let header = """
        <!-- author: \(author)\(email.isEmpty ? "" : " (\(email))") -->
        <!-- created: \(created) -->
        <!-- updated: \(updated) -->
        <!-- comment_id: \(comment.id) -->


        """
        return Data((header + body + "\n").utf8)
    }

    // MARK: - HTML

    /// Generate a self-contained HTML view of an issue including comments,
    /// attachments, and custom fields.
    public static func html(
        _ issue: JiraIssue,
        comments: [JiraComment],
        attachments: [JiraAttachment],
        baseURL: URL,
        fieldNames: [String: String] = [:]
    ) -> Data {
        let f = issue.fields
        let issueURL = baseURL.appendingPathComponent("browse/\(issue.key)")
        let summary = escapeHTML(f.summary ?? "")
        let descMd  = ContentRenderer.renderDescription(f.description)

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(issue.key): \(summary)</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:900px;margin:40px auto;padding:0 20px;color:#1d2125;line-height:1.6}
        h1{font-size:1.5em;margin-bottom:4px}h1 a{color:inherit;text-decoration:none}h1 a:hover{text-decoration:underline}
        h2{font-size:1.1em;margin-top:32px;margin-bottom:8px;border-bottom:1px solid #e0e0e0;padding-bottom:4px}
        .meta-grid{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;margin:16px 0;font-size:.9em}
        .meta-label{color:#626f86;font-weight:600}
        .badge{display:inline-block;padding:2px 8px;border-radius:3px;font-size:.8em;font-weight:600;background:#dfe1e6;color:#172b4d}
        .badge.status{background:#0052cc;color:#fff}
        .badge.priority-highest,.badge.priority-blocker{background:#d04437;color:#fff}
        .badge.priority-high{background:#e65100;color:#fff}
        .badge.priority-medium{background:#e07b00;color:#fff}
        .badge.priority-low,.badge.priority-lowest{background:#44516c;color:#fff}
        pre{background:#f4f5f7;padding:12px;border-radius:4px;overflow-x:auto;font-size:.88em;white-space:pre-wrap}
        .description{background:#f9f9fb;border-left:3px solid #0052cc;padding:12px 16px;border-radius:0 4px 4px 0;margin:8px 0}
        .comment{border:1px solid #e0e0e0;border-radius:4px;margin:12px 0;padding:12px 16px}
        .comment-header{font-size:.85em;color:#626f86;margin-bottom:8px}
        .comment-author{font-weight:600;color:#1d2125}
        table{border-collapse:collapse;width:100%;font-size:.88em}
        th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #e0e0e0}
        th{background:#f4f5f7;font-weight:600}
        .custom-fields-grid{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;font-size:.88em}
        .custom-key{color:#626f86;font-family:monospace;font-size:.85em}
        </style>
        </head>
        <body>
        <h1><a href="\(issueURL.absoluteString)">\(issue.key)</a>: \(summary)</h1>
        <div class="meta-grid">
        """

        func row(_ label: String, _ value: String) {
            html += "<span class=\"meta-label\">\(label)</span><span>\(value)</span>\n"
        }

        if let t = f.issueType?.name { row("Type", escapeHTML(t)) }
        let statusName = f.status?.name ?? ""
        if !statusName.isEmpty {
            html += "<span class=\"meta-label\">Status</span><span><span class=\"badge status\">\(escapeHTML(statusName))</span></span>\n"
        }
        if let p = f.priority?.name {
            let cls = "badge priority-\(p.lowercased())"
            html += "<span class=\"meta-label\">Priority</span><span><span class=\"\(cls)\">\(escapeHTML(p))</span></span>\n"
        }
        if let a = f.assignee?.displayName { row("Assignee", escapeHTML(a)) }
        if let r = f.reporter?.displayName { row("Reporter", escapeHTML(r)) }
        if let created = f.created { row("Created", escapeHTML(created)) }
        if let updated = f.updated { row("Updated", escapeHTML(updated)) }
        if let res = f.resolution?.name { row("Resolution", escapeHTML(res)) }
        if let parent = f.parent?.key { row("Parent", escapeHTML(parent)) }
        let labels = f.labels ?? []
        if !labels.isEmpty { row("Labels", labels.map { escapeHTML($0) }.joined(separator: ", ")) }
        let comps = (f.components ?? []).compactMap { $0.name }
        if !comps.isEmpty { row("Components", comps.map { escapeHTML($0) }.joined(separator: ", ")) }

        html += "</div>\n"

        // Description
        if !descMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            html += "<h2>Description</h2>\n<div class=\"description\"><pre>\(escapeHTML(descMd))</pre></div>\n"
        }

        // Subtasks
        let subtasks = f.subtasks ?? []
        if !subtasks.isEmpty {
            html += "<h2>Subtasks</h2>\n<ul>\n"
            for s in subtasks {
                if let k = s.key {
                    let u = baseURL.appendingPathComponent("browse/\(k)")
                    html += "<li><a href=\"\(u.absoluteString)\">\(escapeHTML(k))</a></li>\n"
                }
            }
            html += "</ul>\n"
        }

        // Links
        let links = f.issuelinks ?? []
        if !links.isEmpty {
            html += "<h2>Links</h2>\n<ul>\n"
            for link in links {
                let dir = link.outwardIssue != nil ? "outward" : "inward"
                let other = link.outwardIssue ?? link.inwardIssue
                let typeName = link.type.name ?? dir
                let key = other?.key ?? "?"
                let u = baseURL.appendingPathComponent("browse/\(key)")
                html += "<li>\(escapeHTML(typeName)): <a href=\"\(u.absoluteString)\">\(escapeHTML(key))</a></li>\n"
            }
            html += "</ul>\n"
        }

        // Custom fields
        if !f.customFields.isEmpty {
            html += "<h2>Custom Fields</h2>\n<div class=\"custom-fields-grid\">\n"
            for key in f.customFields.keys.sorted() {
                let val = customFieldText(f.customFields[key]!)
                // Prefer display name from field metadata; fall back to raw ID.
                let label = fieldNames[key] ?? key
                html += "<span class=\"custom-key\">\(escapeHTML(label))</span><span>\(escapeHTML(val))</span>\n"
            }
            html += "</div>\n"
        }

        // Attachments
        if !attachments.isEmpty {
            html += "<h2>Attachments</h2>\n<table>\n<tr><th>File</th><th>Type</th><th>Size</th><th>Created</th></tr>\n"
            // Compute filesystem filenames the same way JiraVolume+Operations does:
            // sanitize then deduplicate. issue.html lives in the issue directory so
            // the relative path is attachments/<localName>.
            var taken = Set<String>()
            for att in attachments {
                let localName = FileNameSanitizer.deduplicate(
                    FileNameSanitizer.sanitize(att.filename), taken: &taken)
                let localPath = "attachments/\(localName)"
                let link = "<a href=\"\(escapeHTML(localPath))\">\(escapeHTML(att.filename))</a>"
                let mime = escapeHTML(att.mimeType ?? "")
                let size = ByteCountFormatter.string(fromByteCount: Int64(att.size), countStyle: .file)
                let created = escapeHTML(att.created ?? "")
                html += "<tr><td>\(link)</td><td>\(mime)</td><td>\(size)</td><td>\(created)</td></tr>\n"
            }
            html += "</table>\n"
        }

        // Comments
        if !comments.isEmpty {
            html += "<h2>Comments (\(comments.count))</h2>\n"
            for (i, c) in comments.enumerated() {
                let author  = escapeHTML(c.author?.displayName ?? "unknown")
                let created = escapeHTML(c.created ?? "")
                let updated = escapeHTML(c.updated ?? "")
                let body    = escapeHTML(ContentRenderer.renderDescription(c.body))
                html += """
                <div class="comment">
                <div class="comment-header">
                <span class="comment-author">\(author)</span>
                &nbsp;·&nbsp;created: \(created)
                \(updated != created ? "&nbsp;·&nbsp;updated: \(updated)" : "")
                &nbsp;·&nbsp;#\(i + 1)
                </div>
                <pre>\(body)</pre>
                </div>

                """
            }
        }

        html += "</body>\n</html>\n"
        return Data(html.utf8)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func customFieldText(_ v: JSONValue) -> String {
        switch v {
        case .null:          return ""
        case .bool(let b):   return b ? "true" : "false"
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array(let a):  return a.map { customFieldText($0) }.joined(separator: ", ")
        case .object(let o):
            // Common JIRA pattern: objects with a "name", "value", or "displayName" key.
            if case .string(let n) = o["displayName"] { return n }
            if case .string(let n) = o["name"]        { return n }
            if case .string(let n) = o["value"]       { return n }
            // Fallback: key=value pairs
            return o.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\(customFieldText($0.value))" }
                    .joined(separator: " ")
        }
    }

    public static func projectMeta(_ project: JiraProject) -> Data {        let dict: [String: Any] = [
            "id": project.id,
            "key": project.key,
            "name": project.name,
            "projectTypeKey": project.projectTypeKey as Any? ?? NSNull(),
            "lead": project.lead?.displayName as Any? ?? NSNull(),
        ]
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: dict, options: opts)) ?? Data()
    }

    /// Build the comments-directory filename: `NNN_author_YYYY-MM-DD.md`.
    public static func commentFileName(index: Int, comment: JiraComment) -> String {
        let n = String(format: "%03d", index)
        let author = FileNameSanitizer.sanitize(comment.author?.displayName ?? "unknown")
            .replacingOccurrences(of: " ", with: "_")
        let date = String((comment.created ?? "").prefix(10))
        let datePart = date.isEmpty ? "0000-00-00" : date
        return "\(n)_\(author)_\(datePart).md"
    }
}
