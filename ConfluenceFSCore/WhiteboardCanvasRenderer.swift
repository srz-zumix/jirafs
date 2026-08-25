import Foundation
import AtlassianCore

/// Renders the Rovo MCP `getTeamworkGraphObject` response for a whiteboard into
/// Markdown.
///
/// The response nests three levels of JSON: the MCP envelope carries a
/// `bodyValue` string holding the `WHITEBOARD_DOC_FORMAT` canvas, and each
/// canvas node carries its label as an ADF string.
public enum WhiteboardCanvasRenderer {
    /// Returns `nil` when the payload does not match the expected shape so the
    /// caller can fall back to emitting the raw response. The format is beta and
    /// undocumented, so an unexpected shape is normal rather than an error.
    public static func render(_ payload: String) -> String? {
        guard let nodes = canvasKeyedNodes(in: payload) else { return nil }

        var labelled: [String] = []
        var unlabelledTypes: [String: Int] = [:]
        for (_, node) in nodes.sorted(by: readingOrder) {
            guard let obj = node.objectValue else { continue }
            let text = obj["text"].flatMap(adfText) ?? ""
            if text.isEmpty {
                unlabelledTypes[obj["type"]?.stringValue ?? "unknown", default: 0] += 1
            } else {
                labelled.append(text)
            }
        }
        guard !labelled.isEmpty || !unlabelledTypes.isEmpty else { return nil }

        var out = labelled
            .map { "- " + $0.replacingOccurrences(of: "\n", with: "\n  ") }
            .joined(separator: "\n")
        if !unlabelledTypes.isEmpty {
            let summary = unlabelledTypes.sorted { $0.key < $1.key }
                .map { "\($0.key) × \($0.value)" }
                .joined(separator: ", ")
            if !out.isEmpty { out += "\n\n" }
            out += "_Elements without text: \(summary)._"
        }
        return out
    }

    static func canvasNodes(in payload: String) -> [JSONValue]? {
        guard let nodes = canvasDocument(in: payload)?.objectValue?["nodes"]?.objectValue
        else { return nil }
        return Array(nodes.values)
    }

    /// The canvas nodes keyed by their dictionary key, so ordering can tie-break
    /// on a stable identifier instead of `Dictionary` iteration order.
    static func canvasKeyedNodes(in payload: String) -> [(key: String, value: JSONValue)]? {
        guard let nodes = canvasDocument(in: payload)?.objectValue?["nodes"]?.objectValue
        else { return nil }
        return nodes.map { ($0.key, $0.value) }
    }

    static func canvasDocument(in payload: String) -> JSONValue? {
        guard let root = decode(payload)?.objectValue,
              let objects = root["data"]?.objectValue?["data"]?.objectValue?["objects"]?.arrayValue,
              let body = objects.first?.objectValue?["raw"]?.objectValue?["bodyValue"]?.stringValue
        else { return nil }
        return decode(body)
    }

    /// Top-to-bottom, left-to-right across the canvas; the node key breaks ties
    /// so equal-position nodes keep a deterministic order across runs.
    private static func readingOrder(_ lhs: (key: String, value: JSONValue),
                                     _ rhs: (key: String, value: JSONValue)) -> Bool {
        let a = position(of: lhs.value), b = position(of: rhs.value)
        if a.y != b.y { return a.y < b.y }
        if a.x != b.x { return a.x < b.x }
        return lhs.key < rhs.key
    }

    private static func position(of node: JSONValue) -> (x: Double, y: Double) {
        // Match the SVG renderer's `box(of:)`, which falls back to
        // `legacyGeometry` when `geometry` is absent, so ordering stays stable
        // for nodes that only carry the legacy shape.
        let geometry = node.objectValue?["geometry"] ?? node.objectValue?["legacyGeometry"]
        guard let p = geometry?.objectValue?["position"]?.objectValue else {
            return (0, 0)
        }
        func value(_ key: String) -> Double {
            if case .number(let v) = p[key] ?? .null { return v }
            return 0
        }
        return (value("x"), value("y"))
    }

    static func adfText(_ value: JSONValue) -> String? {
        guard let adf = value.stringValue.flatMap(decode) else { return nil }
        return ADFRenderer.render(adf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ json: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
