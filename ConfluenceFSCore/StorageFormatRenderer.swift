import Foundation

/// Converts Confluence **storage format** (XHTML with `ac:`/`ri:` macros) into
/// Markdown. The renderer is deliberately lenient: storage bodies are returned
/// as XML fragments without namespace declarations, so a strict XML parser is
/// unsuitable. Instead a small tokenizer walks the markup and emits Markdown,
/// falling back to the raw body (prefixed with a marker) when the result would
/// be empty.
public enum StorageFormatRenderer {
    public static let defaultRawFallbackMarker = "<!-- confluencefs: raw fallback -->"

    public static func render(_ xhtml: String, rawFallbackMarker: String = defaultRawFallbackMarker) -> String {
        let tokens = Tokenizer(xhtml).tokenized()
        var renderer = Walker()
        let markdown = renderer.render(tokens).trimmingCharacters(in: .whitespacesAndNewlines)
        if markdown.isEmpty && !xhtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rawFallback(xhtml, marker: rawFallbackMarker)
        }
        return markdown
    }

    public static func rawFallback(_ xhtml: String, marker: String = defaultRawFallbackMarker) -> String {
        "\(marker)\n\(xhtml)"
    }

    // MARK: - Tokenizer

    enum Token: Equatable {
        case text(String)
        case open(name: String, attrs: [String: String], selfClosing: Bool)
        case close(name: String)
    }

    struct Tokenizer {
        private let scalars: [Character]
        private var i = 0

        init(_ s: String) { self.scalars = Array(s) }

        func tokenized() -> [Token] {
            var copy = self
            return copy.tokenize()
        }

        mutating func tokenize() -> [Token] {
            var tokens: [Token] = []
            var text = ""
            func flushText() {
                if !text.isEmpty {
                    tokens.append(.text(decodeEntities(text)))
                    text = ""
                }
            }
            while i < scalars.count {
                let c = scalars[i]
                if c == "<" {
                    // CDATA
                    if matches("<![CDATA[") {
                        i += "<![CDATA[".count
                        var cdata = ""
                        while i < scalars.count && !matches("]]>") {
                            cdata.append(scalars[i]); i += 1
                        }
                        i += "]]>".count
                        text += cdata
                        continue
                    }
                    // Comment
                    if matches("<!--") {
                        i += 4
                        while i < scalars.count && !matches("-->") { i += 1 }
                        i += 3
                        continue
                    }
                    flushText()
                    if let tok = readTag() { tokens.append(tok) }
                } else {
                    text.append(c)
                    i += 1
                }
            }
            flushText()
            return tokens
        }

        private func matches(_ s: String) -> Bool {
            let chars = Array(s)
            guard i + chars.count <= scalars.count else { return false }
            for k in 0..<chars.count where scalars[i + k] != chars[k] { return false }
            return true
        }

        private mutating func readTag() -> Token? {
            // assumes scalars[i] == "<"
            i += 1
            var isClose = false
            if i < scalars.count && scalars[i] == "/" { isClose = true; i += 1 }
            var name = ""
            while i < scalars.count, let c = peek(), isNameChar(c) {
                name.append(c); i += 1
            }
            name = name.lowercased()
            // parse attributes
            var attrs: [String: String] = [:]
            var selfClosing = false
            while i < scalars.count {
                skipSpaces()
                guard let c = peek() else { break }
                if c == "/" { selfClosing = true; i += 1; continue }
                if c == ">" { i += 1; break }
                // attribute name
                var attrName = ""
                while i < scalars.count, let ac = peek(), isNameChar(ac) {
                    attrName.append(ac); i += 1
                }
                if attrName.isEmpty { i += 1; continue }
                skipSpaces()
                var value = ""
                if peek() == "=" {
                    i += 1; skipSpaces()
                    if let q = peek(), q == "\"" || q == "'" {
                        i += 1
                        while i < scalars.count, let vc = peek(), vc != q {
                            value.append(vc); i += 1
                        }
                        i += 1 // closing quote
                    } else {
                        while i < scalars.count, let vc = peek(), !vc.isWhitespace, vc != ">" {
                            value.append(vc); i += 1
                        }
                    }
                }
                attrs[attrName.lowercased()] = decodeEntities(value)
            }
            if name.isEmpty { return nil }
            return isClose ? .close(name: name) : .open(name: name, attrs: attrs, selfClosing: selfClosing)
        }

        private func peek() -> Character? { i < scalars.count ? scalars[i] : nil }
        private mutating func skipSpaces() { while i < scalars.count, scalars[i].isWhitespace { i += 1 } }
        private func isNameChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == ":" || c == "-" || c == "_" || c == "."
        }
    }

    // MARK: - Walker (tokens → Markdown)

    struct Walker {
        private var listStack: [(ordered: Bool, index: Int)] = []

        mutating func render(_ tokens: [Token]) -> String {
            var out = ""
            var i = 0
            while i < tokens.count {
                i = emit(tokens, i, into: &out)
            }
            return collapseBlankLines(out)
        }

        /// Emits one token (and possibly its matched subtree) starting at `i`,
        /// returning the index of the next unconsumed token.
        private mutating func emit(_ tokens: [Token], _ i: Int, into out: inout String) -> Int {
            switch tokens[i] {
            case .text(let t):
                out += t
                return i + 1
            case .close:
                return i + 1
            case .open(let name, let attrs, let selfClosing):
                return emitOpen(name: name, attrs: attrs, selfClosing: selfClosing, tokens: tokens, i: i, into: &out)
            }
        }

        private mutating func emitOpen(
            name: String, attrs: [String: String], selfClosing: Bool,
            tokens: [Token], i: Int, into out: inout String
        ) -> Int {
            switch name {
            case "br":
                out += "  \n"; return i + 1
            case "hr":
                out += "\n---\n"; return i + 1
            case "p":
                let (inner, next) = innerText(tokens, after: i, close: name)
                out += inner.trimmingCharacters(in: .whitespaces) + "\n\n"
                return next
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(String(name.dropFirst())) ?? 1
                let (inner, next) = innerText(tokens, after: i, close: name)
                out += String(repeating: "#", count: level) + " " + inner.trimmingCharacters(in: .whitespaces) + "\n\n"
                return next
            case "strong", "b":
                let (inner, next) = innerText(tokens, after: i, close: name)
                out += "**\(inner)**"; return next
            case "em", "i":
                let (inner, next) = innerText(tokens, after: i, close: name)
                out += "*\(inner)*"; return next
            case "code":
                let (inner, next) = innerText(tokens, after: i, close: name)
                out += "`\(inner)`"; return next
            case "pre":
                let (inner, next) = rawInner(tokens, after: i, close: name)
                out += "\n```\n\(inner)\n```\n"; return next
            case "blockquote":
                let (inner, next) = innerText(tokens, after: i, close: name)
                out += quote(inner) + "\n"; return next
            case "a":
                let (inner, next) = innerText(tokens, after: i, close: name)
                let href = attrs["href"] ?? ""
                out += href.isEmpty ? inner : "[\(inner)](\(href))"
                return next
            case "img":
                let alt = attrs["alt"] ?? ""
                let src = attrs["src"] ?? ""
                out += "![\(alt)](\(src))\n\n"
                return i + 1
            case "ul", "ol":
                return emitList(ordered: name == "ol", tokens: tokens, i: i, into: &out)
            case "li":
                // handled inside emitList; if encountered bare, treat as text
                let (inner, next) = innerText(tokens, after: i, close: name)
                out += inner; return next
            case "table":
                return emitTable(tokens: tokens, i: i, into: &out)
            case "ac:structured-macro":
                return emitMacro(attrs: attrs, tokens: tokens, i: i, into: &out)
            case "ri:attachment":
                let file = attrs["ri:filename"] ?? ""
                out += "[\(file)](attachments/\(file))"
                return selfClosing ? i + 1 : skipTo(tokens, after: i, close: name)
            case "ac:link", "ac:image":
                // render inner content (often ri:* or text)
                let (inner, next) = innerText(tokens, after: i, close: name)
                out += inner
                // `ac:image` is a block-level element; separate it from the
                // following block (e.g. a heading) with a blank line so the next
                // block isn't glued onto the image link.
                if name == "ac:image" { out += "\n\n" }
                return next
            default:
                // Unknown tag: ignore the tag itself, keep rendering inner content.
                if selfClosing { return i + 1 }
                return i + 1
            }
        }

        // MARK: list / table / macro helpers

        private mutating func emitList(ordered: Bool, tokens: [Token], i: Int, into out: inout String) -> Int {
            listStack.append((ordered, 0))
            let depth = listStack.count - 1
            var j = i + 1
            out += "\n"
            while j < tokens.count {
                switch tokens[j] {
                case .close(let n) where n == (ordered ? "ol" : "ul"):
                    listStack.removeLast()
                    out += "\n"
                    return j + 1
                case .open(let n, _, _) where n == "li":
                    listStack[depth].index += 1
                    let marker = ordered ? "\(listStack[depth].index)." : "-"
                    let indent = String(repeating: "  ", count: depth)
                    let (inner, next) = listItemInner(tokens, after: j)
                    out += "\(indent)\(marker) \(inner.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    j = next
                default:
                    j += 1
                }
            }
            if !listStack.isEmpty { listStack.removeLast() }
            return j
        }

        /// Renders the inner content of an `<li>`, allowing nested lists.
        private mutating func listItemInner(_ tokens: [Token], after i: Int) -> (String, Int) {
            var out = ""
            var j = i + 1
            var depth = 0
            while j < tokens.count {
                switch tokens[j] {
                case .close(let n) where n == "li" && depth == 0:
                    return (out, j + 1)
                case .open(let n, _, _) where (n == "ul" || n == "ol") && depth == 0:
                    j = emitList(ordered: n == "ol", tokens: tokens, i: j, into: &out)
                case .open(let n, let a, let sc):
                    if n == "li" { depth += 1 }
                    j = emitOpen(name: n, attrs: a, selfClosing: sc, tokens: tokens, i: j, into: &out)
                case .text(let t):
                    out += t; j += 1
                case .close(let n):
                    if n == "li" { depth -= 1 }
                    j += 1
                }
            }
            return (out, j)
        }

        private mutating func emitTable(tokens: [Token], i: Int, into out: inout String) -> Int {
            var rows: [[String]] = []
            var headerSeen = false
            var j = i + 1
            var currentRow: [String] = []
            while j < tokens.count {
                switch tokens[j] {
                case .close(let n) where n == "table":
                    j += 1
                    renderTable(rows, headerSeen: headerSeen, into: &out)
                    return j
                case .open(let n, _, _) where n == "tr":
                    currentRow = []
                    j += 1
                case .close(let n) where n == "tr":
                    rows.append(currentRow)
                    j += 1
                case .open(let n, _, _) where n == "th" || n == "td":
                    if n == "th" { headerSeen = true }
                    let (inner, next) = innerText(tokens, after: j, close: n)
                    currentRow.append(inner.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " "))
                    j = next
                default:
                    j += 1
                }
            }
            renderTable(rows, headerSeen: headerSeen, into: &out)
            return j
        }

        private func renderTable(_ rows: [[String]], headerSeen: Bool, into out: inout String) {
            guard !rows.isEmpty else { return }
            let cols = rows.map(\.count).max() ?? 0
            guard cols > 0 else { return }
            out += "\n"
            for (idx, row) in rows.enumerated() {
                var cells = row
                if cells.count < cols { cells += Array(repeating: "", count: cols - cells.count) }
                out += "| " + cells.joined(separator: " | ") + " |\n"
                if idx == 0 {
                    out += "|" + Array(repeating: " --- ", count: cols).joined(separator: "|") + "|\n"
                }
            }
            out += "\n"
        }

        private mutating func emitMacro(attrs: [String: String], tokens: [Token], i: Int, into out: inout String) -> Int {
            let macroName = attrs["ac:name"] ?? ""
            // Collect the macro subtree.
            let (subtree, next) = subtreeTokens(tokens, after: i, close: "ac:structured-macro")
            switch macroName {
            case "code":
                let lang = parameterValue(in: subtree, name: "language") ?? ""
                let body = plainTextBody(in: subtree)
                out += "\n```\(lang)\n\(body)\n```\n"
            case "info", "note", "warning", "tip", "panel":
                var inner = ""
                var w = Walker()
                inner = w.render(richTextBody(in: subtree))
                out += quote(inner.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n"
            case "noformat":
                let body = plainTextBody(in: subtree)
                out += "\n```\n\(body)\n```\n"
            default:
                // Render any rich-text body of unknown macros inline.
                var w = Walker()
                out += w.render(richTextBody(in: subtree))
            }
            return next
        }

        // MARK: token-subtree utilities

        /// Returns the inner text of an element, rendering inline children.
        private mutating func innerText(_ tokens: [Token], after i: Int, close name: String) -> (String, Int) {
            if case .open(_, _, let selfClosing) = tokens[i], selfClosing {
                return ("", i + 1)
            }
            var out = ""
            var j = i + 1
            var depth = 0
            while j < tokens.count {
                switch tokens[j] {
                case .close(let n) where n == name && depth == 0:
                    return (out, j + 1)
                case .open(let n, let a, let sc):
                    if n == name && !sc { depth += 1 }
                    j = emitOpen(name: n, attrs: a, selfClosing: sc, tokens: tokens, i: j, into: &out)
                case .close(let n):
                    if n == name { depth -= 1 }
                    j += 1
                case .text(let t):
                    out += t; j += 1
                }
            }
            return (out, j)
        }

        /// Returns the raw concatenated text (no markdown formatting) of an element.
        private func rawInner(_ tokens: [Token], after i: Int, close name: String) -> (String, Int) {
            var out = ""
            var j = i + 1
            var depth = 0
            while j < tokens.count {
                switch tokens[j] {
                case .close(let n) where n == name && depth == 0:
                    return (out, j + 1)
                case .open(let n, _, let sc):
                    if n == name && !sc { depth += 1 }
                    j += 1
                case .close(let n):
                    if n == name { depth -= 1 }
                    j += 1
                case .text(let t):
                    out += t; j += 1
                }
            }
            return (out, j)
        }

        private func skipTo(_ tokens: [Token], after i: Int, close name: String) -> Int {
            var j = i + 1
            while j < tokens.count {
                if case .close(let n) = tokens[j], n == name { return j + 1 }
                j += 1
            }
            return j
        }

        private func subtreeTokens(_ tokens: [Token], after i: Int, close name: String) -> ([Token], Int) {
            var sub: [Token] = []
            var j = i + 1
            var depth = 0
            while j < tokens.count {
                switch tokens[j] {
                case .close(let n) where n == name && depth == 0:
                    return (sub, j + 1)
                case .open(let n, _, let sc):
                    if n == name && !sc { depth += 1 }
                    sub.append(tokens[j]); j += 1
                case .close(let n):
                    if n == name { depth -= 1 }
                    sub.append(tokens[j]); j += 1
                case .text:
                    sub.append(tokens[j]); j += 1
                }
            }
            return (sub, j)
        }

        /// Extracts `<ac:parameter ac:name="X">value</ac:parameter>` text.
        private func parameterValue(in tokens: [Token], name: String) -> String? {
            var j = 0
            while j < tokens.count {
                if case .open(let n, let a, _) = tokens[j], n == "ac:parameter", a["ac:name"] == name {
                    var value = ""
                    var k = j + 1
                    while k < tokens.count {
                        if case .close(let cn) = tokens[k], cn == "ac:parameter" { break }
                        if case .text(let t) = tokens[k] { value += t }
                        k += 1
                    }
                    return value
                }
                j += 1
            }
            return nil
        }

        /// Extracts the text inside `<ac:plain-text-body>` (CDATA).
        private func plainTextBody(in tokens: [Token]) -> String {
            extractBody(in: tokens, tag: "ac:plain-text-body").map { tok -> String in
                if case .text(let t) = tok { return t }
                return ""
            }.joined()
        }

        /// Extracts the tokens inside `<ac:rich-text-body>` for recursive rendering.
        private func richTextBody(in tokens: [Token]) -> [Token] {
            extractBody(in: tokens, tag: "ac:rich-text-body")
        }

        private func extractBody(in tokens: [Token], tag: String) -> [Token] {
            var j = 0
            while j < tokens.count {
                if case .open(let n, _, _) = tokens[j], n == tag {
                    var sub: [Token] = []
                    var k = j + 1
                    var depth = 0
                    while k < tokens.count {
                        if case .close(let cn) = tokens[k], cn == tag, depth == 0 { return sub }
                        if case .open(let on, _, let sc) = tokens[k], on == tag, !sc { depth += 1 }
                        if case .close(let cn) = tokens[k], cn == tag { depth -= 1 }
                        sub.append(tokens[k]); k += 1
                    }
                    return sub
                }
                j += 1
            }
            return []
        }

        private func quote(_ s: String) -> String {
            s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
        }

        private func collapseBlankLines(_ s: String) -> String {
            var result = ""
            var blankRun = 0
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    blankRun += 1
                    if blankRun <= 1 { result += "\n" }
                } else {
                    blankRun = 0
                    result += line + "\n"
                }
            }
            return result
        }
    }
}

// MARK: - HTML entities

private func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var result = s
    let named: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
        "&hellip;": "…", "&copy;": "©", "&reg;": "®", "&trade;": "™",
    ]
    for (k, v) in named { result = result.replacingOccurrences(of: k, with: v) }
    // numeric entities &#NN; and &#xHH;
    result = replaceNumericEntities(result)
    return result
}

private func replaceNumericEntities(_ s: String) -> String {
    guard s.contains("&#") else { return s }
    var out = ""
    var idx = s.startIndex
    while idx < s.endIndex {
        if s[idx] == "&", let semi = s[idx...].firstIndex(of: ";"),
           s.index(after: idx) < s.endIndex, s[s.index(after: idx)] == "#" {
            let entity = s[s.index(idx, offsetBy: 2)..<semi]
            var scalarValue: UInt32?
            if entity.first == "x" || entity.first == "X" {
                scalarValue = UInt32(entity.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(entity, radix: 10)
            }
            if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                out.append(Character(scalar))
                idx = s.index(after: semi)
                continue
            }
        }
        out.append(s[idx])
        idx = s.index(after: idx)
    }
    return out
}
