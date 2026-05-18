import Foundation

/// Identifies what JIRA resource a filesystem path maps to.
public enum FSNodeKind: Hashable, Sendable {
    case root
    case metadataNeverIndex          // /.metadata_never_index (prevents Spotlight indexing)
    case configDir                   // /.jirafs
    case configFile                  // /.jirafs/config.json
    case projectsDir                 // /projects
    case project(key: String)        // /projects/{KEY}
    case projectMeta(key: String)    // /projects/{KEY}/.project.json
    case issuesDir(project: String)  // /projects/{KEY}/issues
    case issue(key: String)          // /projects/{KEY}/issues/{ISSUE-KEY}
    case summary(issueKey: String)
    case description(issueKey: String)
    case metadata(issueKey: String)
    case issueHtml(issueKey: String)   // /projects/{KEY}/issues/{ISSUE-KEY}/issue.html
    case commentsDir(issueKey: String)
    case comment(issueKey: String, index: Int)  // 1-based; stable across deduplication
    case attachmentsDir(issueKey: String)
    case attachment(issueKey: String, attachmentId: String)  // stable JiraAttachment.id

    public var isDirectory: Bool {
        switch self {
        case .root, .configDir, .projectsDir, .project, .issuesDir, .issue,
             .commentsDir, .attachmentsDir:
            return true
        default:
            return false
        }
    }
}

/// Validates and converts between filesystem paths and `FSNodeKind`s.
public enum PathResolver {
    /// Names of files exposed inside an issue directory.
    public enum IssueFile: String, CaseIterable, Sendable {
        case summary = "summary.txt"
        case description = "description.md"
        case metadata = "metadata.json"
    }

    /// Standard children of an issue directory in lookup order.
    public static let issueChildFiles: [IssueFile] = IssueFile.allCases

    public static func childKinds(of parent: FSNodeKind, projectKeys: [String] = []) -> [(name: String, kind: FSNodeKind)] {
        switch parent {
        case .root:
            return [
                ("projects", .projectsDir),
                (".jirafs", .configDir),
                (".metadata_never_index", .metadataNeverIndex),
            ]
        case .configDir:
            return [("config.json", .configFile)]
        case .projectsDir:
            return projectKeys.map { ($0, FSNodeKind.project(key: $0)) }
        case .project(let key):
            return [
                (".project.json", .projectMeta(key: key)),
                ("issues", .issuesDir(project: key)),
            ]
        case .issue(let key):
            return [
                ("summary.txt", .summary(issueKey: key)),
                ("description.md", .description(issueKey: key)),
                ("metadata.json", .metadata(issueKey: key)),
                ("comments", .commentsDir(issueKey: key)),
                ("attachments", .attachmentsDir(issueKey: key)),
            ]
        default:
            return []
        }
    }

    /// Resolve a child name against a parent kind. Returns nil if the name
    /// cannot be a static child (callers must consult JIRA for dynamic ones).
    public static func staticChild(name: String, of parent: FSNodeKind) -> FSNodeKind? {
        for (n, k) in childKinds(of: parent) where n == name {
            return k
        }
        if case .issue(let key) = parent {
            switch name {
            case "summary.txt": return .summary(issueKey: key)
            case "description.md": return .description(issueKey: key)
            case "metadata.json": return .metadata(issueKey: key)
            case "comments": return .commentsDir(issueKey: key)
            case "attachments": return .attachmentsDir(issueKey: key)
            default: return nil
            }
        }
        return nil
    }
}
