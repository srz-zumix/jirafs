import Foundation
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
            return ADFRenderer.render(value)
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

// MARK: - ADF

/// Atlassian Document Format → Markdown. Covers paragraph, heading, lists,
/// codeBlock, link, mention, hardBreak, rule, blockquote, panel, table.
enum ADFRenderer {
    static func render(_ value: JSONValue) -> String {
        guard case .object(let root) = value else {
            return ContentRenderer.rawFallback(value)
        }
        guard case .array(let content) = root["content"] ?? .null else {
            return ""
        }
        var out = ""
        for node in content {
            out += renderBlock(node)
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderBlock(_ node: JSONValue) -> String {
        guard case .object(let obj) = node,
              case .string(let type) = obj["type"] ?? .null else {
            return ""
        }
        let inner: [JSONValue] = {
            if case .array(let a) = obj["content"] ?? .null { return a }
            return []
        }()
        let attrs: [String: JSONValue] = {
            if case .object(let a) = obj["attrs"] ?? .null { return a }
            return [:]
        }()
        switch type {
        case "paragraph":
            return renderInline(inner) + "\n"
        case "heading":
            let level: Int = {
                if case .number(let n) = attrs["level"] ?? .null { return Int(n) }
                return 1
            }()
            let prefix = String(repeating: "#", count: max(1, min(6, level)))
            return "\(prefix) \(renderInline(inner))\n"
        case "bulletList":
            return inner.map { "- \(renderListItem($0))" }.joined(separator: "\n") + "\n"
        case "orderedList":
            return inner.enumerated().map { "\($0 + 1). \(renderListItem($1))" }.joined(separator: "\n") + "\n"
        case "codeBlock":
            let lang: String = {
                if case .string(let s) = attrs["language"] ?? .null { return s }
                return ""
            }()
            return "```\(lang)\n\(renderPlain(inner))\n```\n"
        case "blockquote":
            let body = inner.map(renderBlock).joined()
            return body.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n"
        case "rule":
            return "---\n"
        case "panel":
            let body = inner.map(renderBlock).joined()
            return body.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n"
        case "table":
            return renderTable(inner) + "\n"
        case "mediaSingle", "mediaGroup":
            return inner.map(renderBlock).joined()
        case "media":
            let alt: String = {
                if case .string(let s) = attrs["alt"] ?? .null { return s }
                return ""
            }()
            return "![\(alt)](attachment)\n"
        default:
            return renderInline(inner) + "\n"
        }
    }

    private static func renderListItem(_ node: JSONValue) -> String {
        guard case .object(let obj) = node,
              case .array(let inner) = obj["content"] ?? .null else { return "" }
        return inner.map(renderBlock).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderInline(_ nodes: [JSONValue]) -> String {
        nodes.map(renderInlineNode).joined()
    }

    private static func renderInlineNode(_ node: JSONValue) -> String {
        guard case .object(let obj) = node,
              case .string(let type) = obj["type"] ?? .null else { return "" }
        switch type {
        case "text":
            let text: String = {
                if case .string(let s) = obj["text"] ?? .null { return s }
                return ""
            }()
            var out = text
            if case .array(let marks) = obj["marks"] ?? .null {
                for mark in marks {
                    out = applyMark(mark, to: out)
                }
            }
            return out
        case "hardBreak":
            return "  \n"
        case "mention":
            if case .object(let attrs) = obj["attrs"] ?? .null,
               case .string(let name) = attrs["text"] ?? .null {
                return "@\(name)"
            }
            return "@?"
        case "emoji":
            if case .object(let attrs) = obj["attrs"] ?? .null,
               case .string(let shortName) = attrs["shortName"] ?? .null {
                return shortName
            }
            return ""
        default:
            if case .array(let inner) = obj["content"] ?? .null {
                return renderInline(inner)
            }
            return ""
        }
    }

    private static func applyMark(_ mark: JSONValue, to text: String) -> String {
        guard case .object(let obj) = mark,
              case .string(let type) = obj["type"] ?? .null else { return text }
        switch type {
        case "strong": return "**\(text)**"
        case "em": return "*\(text)*"
        case "code": return "`\(text)`"
        case "strike": return "~~\(text)~~"
        case "link":
            var href = ""
            if case .object(let attrs) = obj["attrs"] ?? .null,
               case .string(let s) = attrs["href"] ?? .null {
                href = s
            }
            return "[\(text)](\(href))"
        default: return text
        }
    }

    private static func renderPlain(_ nodes: [JSONValue]) -> String {
        nodes.map { node -> String in
            if case .object(let obj) = node,
               case .string(let type) = obj["type"] ?? .null,
               type == "text",
               case .string(let text) = obj["text"] ?? .null {
                return text
            }
            return ""
        }.joined()
    }

    private static func renderTable(_ rows: [JSONValue]) -> String {
        var lines: [String] = []
        var columns = 0
        for (i, row) in rows.enumerated() {
            guard case .object(let obj) = row,
                  case .array(let cells) = obj["content"] ?? .null else { continue }
            columns = max(columns, cells.count)
            let texts = cells.map { cell -> String in
                if case .object(let cobj) = cell,
                   case .array(let inner) = cobj["content"] ?? .null {
                    return inner.map(renderBlock).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return ""
            }
            lines.append("| " + texts.joined(separator: " | ") + " |")
            if i == 0 {
                lines.append("|" + Array(repeating: " --- ", count: texts.count).joined(separator: "|") + "|")
            }
        }
        return lines.joined(separator: "\n")
    }
}

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
