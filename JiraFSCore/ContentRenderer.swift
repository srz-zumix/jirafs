import Foundation
import AtlassianCore
import JiraAPI

/// Renders JIRA description/comment bodies (ADF on Cloud, wiki markup on
/// Server) to Markdown.
///
/// The implementation is intentionally pragmatic — it covers the most common
/// nodes called out in `Documentation/SPEC.md`. Anything unhandled falls back to the
/// raw payload with a `<!-- jirafs: raw fallback -->` marker so a curious user
/// can still read the content.
public enum ContentRenderer {
    public static let rawFallbackMarker = "<!-- jirafs: raw fallback -->"

    /// Render a description-like field (may be ADF object, wiki markup string,
    /// or null). Always returns Markdown text.
    public static func renderDescription(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null:
            return ""
        case .string(let s):
            // Server / wiki markup
            return WikiMarkupRenderer.render(s)
        case .object:
            // Cloud / ADF
            return ADFRenderer.render(value, rawFallbackMarker: rawFallbackMarker)
        default:
            return rawFallback(value)
        }
    }

    static func rawFallback(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = (try? encoder.encode(value)) ?? Data()
        let raw = String(data: data, encoding: .utf8) ?? ""
        return "\(rawFallbackMarker)\n\(raw)"
    }
}

// `ADFRenderer` moved to `AtlassianCore` (shared with Confluence).

// MARK: - Wiki Markup

/// Minimal wiki-markup → Markdown translator for JIRA Server.
enum WikiMarkupRenderer {
    static func render(_ source: String) -> String {
        var out = source
        // Headings: h1. through h6.
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level)
            let pattern = "(?m)^h\(level)\\. "
            out = out.replacingOccurrences(of: pattern, with: "\(prefix) ", options: .regularExpression)
        }
        // {code} / {code:lang}
        out = out.replacingOccurrences(of: "{code:([^}]*)}", with: "```$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "{code}", with: "```")
        // {quote}
        out = out.replacingOccurrences(of: "{quote}", with: "")
        // {panel} / {panel:...}
        out = out.replacingOccurrences(of: "\\{panel(:[^}]*)?\\}", with: "", options: .regularExpression)
        // Bold *text* (already markdown-ish, JIRA single-asterisk -> markdown bold needs **)
        out = out.replacingOccurrences(of: "\\*([^*\\n]+)\\*", with: "**$1**", options: .regularExpression)
        // Italic _text_ (markdown also supports underscores; leave as-is)
        // Links [text|url]
        out = out.replacingOccurrences(of: "\\[([^\\]|]+)\\|([^\\]]+)\\]", with: "[$1]($2)", options: .regularExpression)
        // Bullet list "* item" / "- item" already markdown
        // Numbered list "# item" → "1. item" (rough)
        out = out.replacingOccurrences(of: "(?m)^# ", with: "1. ", options: .regularExpression)
        return out
    }
}
