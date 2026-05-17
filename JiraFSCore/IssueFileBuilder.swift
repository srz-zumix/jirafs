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

    public static func projectMeta(_ project: JiraProject) -> Data {
        let dict: [String: Any] = [
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
