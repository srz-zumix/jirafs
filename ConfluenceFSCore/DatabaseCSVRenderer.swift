import Foundation

/// Renders the CSV a Confluence database is served as (via Rovo MCP) into
/// Markdown tables.
///
/// The payload is not a single table: it is several CSV blocks separated by a
/// blank line — the field definitions, the saved views, and finally the entries
/// themselves. Each block has its own header row, so they are rendered as
/// separate sections rather than being forced into one table.
public enum DatabaseCSVRenderer {
    public struct Section: Sendable, Equatable {
        public let header: [String]
        public let rows: [[String]]

        /// Heading derived from the block's first column, which identifies the
        /// block kind in the payloads Confluence emits.
        public var title: String {
            switch header.first {
            case "field_name": return "Fields"
            case "view_name": return "Views"
            case "_id": return "Entries"
            default: return "Data"
            }
        }
    }

    /// Splits the payload into its blank-line-separated blocks. Returns an empty
    /// array when the CSV holds no usable rows.
    public static func sections(_ csv: String) -> [Section] {
        var sections: [Section] = []
        var current: [[String]] = []
        func flush() {
            guard let header = current.first else { return }
            sections.append(Section(header: header, rows: Array(current.dropFirst())))
            current = []
        }
        for record in records(csv) {
            if record.allSatisfy({ $0.isEmpty }) {
                flush()
            } else {
                current.append(record)
            }
        }
        flush()
        return sections
    }

    /// The whole payload as Markdown. Falls back to a fenced CSV block when the
    /// text does not parse into any table.
    public static func render(_ csv: String) -> String {
        let sections = sections(csv)
        guard !sections.isEmpty else {
            return "```csv\n\(csv.hasSuffix("\n") ? csv : csv + "\n")```\n"
        }
        return sections.map { "## \($0.title)\n\n\(table($0))" }.joined(separator: "\n")
    }

    static func table(_ section: Section) -> String {
        let width = max(section.header.count, section.rows.map(\.count).max() ?? 0)
        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: width - cells.count)
            return "| " + padded.map(escape).joined(separator: " | ") + " |\n"
        }
        var out = row(section.header)
        out += "|" + String(repeating: " --- |", count: width) + "\n"
        for cells in section.rows { out += row(cells) }
        return out
    }

    /// Markdown table cells cannot contain a raw `|` or a line break.
    static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    /// RFC 4180 record splitter: honours quoted fields (including `""` escapes
    /// and embedded separators/newlines) and accepts CRLF, LF or CR line endings.
    ///
    /// Iterates Unicode *scalars* rather than `Character`s because Swift treats
    /// CRLF as a single grapheme cluster, which would otherwise match neither
    /// `\r` nor `\n` and swallow the line break into the field.
    static func records(_ csv: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(csv.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.unicodeScalars.append(scalar)
                }
                index += 1
                continue
            }
            switch scalar {
            case "\"":
                inQuotes = true
            case ",":
                record.append(field)
                field = ""
            case "\r", "\n":
                if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    index += 1
                }
                record.append(field)
                field = ""
                records.append(record)
                record = []
            default:
                field.unicodeScalars.append(scalar)
            }
            index += 1
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}
