import Foundation

/// Atlassian Document Format → Markdown. Covers paragraph, heading, lists,
/// codeBlock, link, mention, hardBreak, rule, blockquote, panel, table.
///
/// Shared by JIRA (Cloud descriptions/comments) and Confluence (Cloud page
/// bodies in `atlas_doc_format`).
public enum ADFRenderer {
    public static let defaultRawFallbackMarker = "<!-- atlassian: raw fallback -->"

    /// Produce a raw JSON fallback prefixed with `marker` for content the
    /// renderer does not understand.
    public static func rawFallback(_ value: JSONValue, marker: String = defaultRawFallbackMarker) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = (try? encoder.encode(value)) ?? Data()
        let raw = String(data: data, encoding: .utf8) ?? ""
        return "\(marker)\n\(raw)"
    }

    public static func render(_ value: JSONValue,
                              rawFallbackMarker: String = defaultRawFallbackMarker) -> String {
        guard case .object(let root) = value else {
            return rawFallback(value, marker: rawFallbackMarker)
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
        // First pass: determine the maximum column count across all rows.
        let maxColumns = rows.reduce(0) { max, row -> Int in
            guard case .object(let obj) = row,
                  case .array(let cells) = obj["content"] ?? .null else { return max }
            return Swift.max(max, cells.count)
        }
        guard maxColumns > 0 else { return "" }
        var lines: [String] = []
        for (i, row) in rows.enumerated() {
            guard case .object(let obj) = row,
                  case .array(let cells) = obj["content"] ?? .null else { continue }
            var texts = cells.map { cell -> String in
                if case .object(let cobj) = cell,
                   case .array(let inner) = cobj["content"] ?? .null {
                    return inner.map(renderBlock).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return ""
            }
            // Pad rows that have fewer cells than the widest row.
            if texts.count < maxColumns {
                texts += Array(repeating: "", count: maxColumns - texts.count)
            }
            lines.append("| " + texts.joined(separator: " | ") + " |")
            if i == 0 {
                lines.append("|" + Array(repeating: " --- ", count: maxColumns).joined(separator: "|") + "|")
            }
        }
        return lines.joined(separator: "\n")
    }
}
