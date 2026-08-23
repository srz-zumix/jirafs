import Foundation
import AtlassianCore

/// Draws the Rovo MCP whiteboard payload as an approximate SVG of the canvas.
///
/// This is a layout sketch, not a faithful reproduction: sticky notes, freehand
/// strokes and connectors are redrawn from the stored geometry, while images are
/// placeholders because their bytes live behind the Media API.
///
/// Coordinates are canvas-absolute and `geometry.position` is the **centre** of
/// a node, not its top-left corner.
public enum WhiteboardSVGRenderer {
    private static let padding = 48.0
    private static let baseFontSize = 16.0
    private static let imageLabelLineHeight = 14.0
    private static let fontFamily = "-apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif"

    /// Returns `nil` when the payload does not match the expected shape so the
    /// caller can emit a placeholder instead.
    public static func render(_ payload: String, title: String) -> String? {
        guard let document = WhiteboardCanvasRenderer.canvasDocument(in: payload)?.objectValue,
              let nodes = document["nodes"]?.objectValue, !nodes.isEmpty
        else { return nil }
        let canvas = Canvas(nodes: nodes, edges: document["edges"]?.objectValue ?? [:])
        let ordered = nodes.values.sorted { zIndex($0) < zIndex($1) }

        var frame: Rect?
        for node in ordered { frame = Rect.union(frame, bounds(of: node, in: canvas)) }
        guard var viewBox = frame else { return nil }
        viewBox = viewBox.expanded(by: padding)

        var body = ""
        var usesArrow = false
        for node in ordered {
            switch kind(of: node) {
            case "sticky", "text", "shape": body += stickyElement(node)
            case "drawing": body += drawingElement(node)
            case "connector": body += connectorElement(node, in: canvas, usesArrow: &usesArrow)
            case "image": body += imageElement(node)
            default: body += unknownElement(node)
            }
        }
        guard !body.isEmpty else { return nil }

        var out = """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(f(viewBox.minX)) \(f(viewBox.minY)) \
            \(f(viewBox.width)) \(f(viewBox.height))" width="\(f(viewBox.width))" \
            height="\(f(viewBox.height))">
            <title>\(escape(title))</title>
            <rect x="\(f(viewBox.minX))" y="\(f(viewBox.minY))" width="\(f(viewBox.width))" \
            height="\(f(viewBox.height))" fill="#ffffff"/>

            """
        if usesArrow {
            out += """
                <defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" \
                markerHeight="6" orient="auto-start-reverse">\
                <path d="M 0 0 L 10 5 L 0 10 z" fill="#626f86"/></marker></defs>

                """
        }
        out += body
        out += "</svg>\n"
        return out
    }

    // MARK: - Elements

    private static func stickyElement(_ node: JSONValue) -> String {
        guard let box = box(of: node) else { return "" }
        let fill = color(node["color"]?.stringValue, fallback: "#f8e6a0")
        var out = "<rect x=\"\(f(box.minX))\" y=\"\(f(box.minY))\" width=\"\(f(box.width))\" "
        out += "height=\"\(f(box.height))\" rx=\"4\" fill=\"\(fill)\" stroke=\"#00000014\""
        out += rotation(node, around: box) + "/>\n"

        guard let text = node["text"].flatMap(WhiteboardCanvasRenderer.adfText), !text.isEmpty else {
            return out
        }
        let size = baseFontSize * (number(node["fontScale"]) ?? 1)
        let lines = wrap(text, within: box.width - 16, fontSize: size)
        let first = box.midY - (Double(lines.count - 1) * size * 1.25) / 2 + size * 0.35
        out += "<text x=\"\(f(box.midX))\" y=\"\(f(first))\" font-family=\"\(fontFamily)\" "
        out += "font-size=\"\(f(size))\" fill=\"#172b4d\" text-anchor=\"middle\""
        out += rotation(node, around: box) + ">\n"
        for (index, line) in lines.enumerated() {
            let dy = index == 0 ? "0" : f(size * 1.25)
            out += "<tspan x=\"\(f(box.midX))\" dy=\"\(dy)\">\(escape(line))</tspan>\n"
        }
        return out + "</text>\n"
    }

    private static func drawingElement(_ node: JSONValue) -> String {
        let points = dedupe(strokePoints(node))
        guard points.count > 1 else { return "" }
        let stroke = color(node["color"]?.stringValue, fallback: "#44546f")
        return """
            <path d="\(smoothPath(points))" fill="none" stroke="\(stroke)" \
            stroke-width="\(f(strokeWidth(node)))" stroke-linecap="round" stroke-linejoin="round"/>

            """
    }

    private static func connectorElement(_ node: JSONValue, in canvas: Canvas,
                                         usesArrow: inout Bool) -> String {
        let route = connectorRoute(node, in: canvas)
        guard route.count > 1 else { return "" }
        let stroke = color(node["color"]?.stringValue, fallback: "#626f86")
        var out = "<path d=\"\(path(through: route, cornerRadius: connectorCornerRadius))\" "
        out += "fill=\"none\" stroke=\"\(stroke)\" stroke-width=\"\(f(strokeWidth(node)))\" "
        out += "stroke-linecap=\"round\" stroke-linejoin=\"round\""
        if node["strokeStyle"]?.stringValue == "dashed" { out += " stroke-dasharray=\"6 4\"" }
        if node["startCap"]?.stringValue == "arrow" {
            usesArrow = true
            out += " marker-start=\"url(#arrow)\""
        }
        if node["endCap"]?.stringValue == "arrow" {
            usesArrow = true
            out += " marker-end=\"url(#arrow)\""
        }
        return out + "/>\n"
    }

    /// Whiteboard images live in Atlassian Media Services, which is unreachable with a
    /// Confluence API token, so only a placeholder carrying the node's metadata is drawn.
    private static func imageElement(_ node: JSONValue) -> String {
        guard let box = box(of: node) else { return "" }
        var out = "<rect x=\"\(f(box.minX))\" y=\"\(f(box.minY))\" width=\"\(f(box.width))\" "
        out += "height=\"\(f(box.height))\" fill=\"#f1f2f4\" stroke=\"#8590a2\" "
        out += "stroke-dasharray=\"6 4\"" + rotation(node, around: box) + "/>\n"

        var labels = [node["mimeType"]?.stringValue ?? "image"]
        if let width = number(node["nativeSize"]?["x"]), let height = number(node["nativeSize"]?["y"]) {
            labels.append("\(f(width)) × \(f(height))")
        }
        if let fileID = node["fileId"]?.stringValue.map({ String($0.prefix(8)) }) {
            labels.append(fileID)
        }
        labels = Array(labels.prefix(max(1, Int(box.height / imageLabelLineHeight) - 1)))

        let firstLine = box.midY - imageLabelLineHeight * Double(labels.count - 1) / 2
        out += "<text x=\"\(f(box.midX))\" y=\"\(f(firstLine))\" font-family=\"\(fontFamily)\" "
        out += "font-size=\"12\" fill=\"#626f86\" text-anchor=\"middle\">"
        out += labels.enumerated().map { index, label in
            let dy = index == 0 ? "0" : f(imageLabelLineHeight)
            return "<tspan x=\"\(f(box.midX))\" dy=\"\(dy)\">\(escape(label))</tspan>"
        }.joined()
        return out + "</text>\n"
    }

    private static func unknownElement(_ node: JSONValue) -> String {
        guard let box = box(of: node) else { return "" }
        return """
            <rect x="\(f(box.minX))" y="\(f(box.minY))" width="\(f(box.width))" \
            height="\(f(box.height))" fill="none" stroke="#c1c7d0" stroke-dasharray="4 4"/>

            """
    }

    // MARK: - Geometry

    private struct Rect {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
        var midX: Double { (minX + maxX) / 2 }
        var midY: Double { (minY + maxY) / 2 }

        func expanded(by amount: Double) -> Rect {
            Rect(minX: minX - amount, minY: minY - amount,
                 maxX: maxX + amount, maxY: maxY + amount)
        }

        static func union(_ lhs: Rect?, _ rhs: Rect?) -> Rect? {
            guard let lhs else { return rhs }
            guard let rhs else { return lhs }
            return Rect(minX: min(lhs.minX, rhs.minX), minY: min(lhs.minY, rhs.minY),
                        maxX: max(lhs.maxX, rhs.maxX), maxY: max(lhs.maxY, rhs.maxY))
        }
    }

    /// Freehand strokes carry absolute points, so their bounds come from those
    /// rather than from the (stroke-padded) geometry.
    private static func bounds(of node: JSONValue, in canvas: Canvas) -> Rect? {
        if kind(of: node) == "drawing" {
            let points = strokePoints(node)
            guard let first = points.first else { return box(of: node) }
            return points.dropFirst().reduce(
                Rect(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
            ) { rect, point in
                Rect(minX: min(rect.minX, point.x), minY: min(rect.minY, point.y),
                     maxX: max(rect.maxX, point.x), maxY: max(rect.maxY, point.y))
            }
        }
        if kind(of: node) == "connector" {
            let route = connectorRoute(node, in: canvas)
            guard let first = route.first else { return nil }
            return route.dropFirst().reduce(
                Rect(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
            ) { rect, point in
                Rect(minX: min(rect.minX, point.x), minY: min(rect.minY, point.y),
                     maxX: max(rect.maxX, point.x), maxY: max(rect.maxY, point.y))
            }
        }
        return box(of: node)
    }

    private static func box(of node: JSONValue) -> Rect? {
        let geometry = node["geometry"] ?? node["legacyGeometry"]
        guard let centre = point(geometry?["position"]), let size = point(geometry?["size"])
        else { return nil }
        return Rect(minX: centre.x - size.x / 2, minY: centre.y - size.y / 2,
                    maxX: centre.x + size.x / 2, maxY: centre.y + size.y / 2)
    }

    /// Stroke points are objects keyed `"0"` / `"1"` rather than `x` / `y`.
    private static func strokePoints(_ node: JSONValue) -> [(x: Double, y: Double)] {
        (node["points"]?.arrayValue ?? []).compactMap { entry in
            guard let x = number(entry["0"]), let y = number(entry["1"]) else { return nil }
            return (x, y)
        }
    }

    private static func point(_ value: JSONValue?) -> (x: Double, y: Double)? {
        guard let x = number(value?["x"]), let y = number(value?["y"]) else { return nil }
        return (x, y)
    }

    // MARK: - Connector routing

    private struct Canvas {
        let nodes: [String: JSONValue]
        let edges: [String: JSONValue]
    }

    private static let connectorStub = 24.0
    private static let connectorCornerRadius = 8.0

    /// `presentation: "dynamic"` connectors are routed orthogonally in
    /// Confluence: they leave the source and enter the target perpendicular to
    /// the anchored edge, so a straight chord would look nothing like the board.
    private static func connectorRoute(_ node: JSONValue,
                                       in canvas: Canvas) -> [(x: Double, y: Double)] {
        let edge = node["id"]?.stringValue.flatMap { canvas.edges[$0] }
        let source = edge?["sourceNode"]?.stringValue.flatMap { canvas.nodes[$0] }
        let target = edge?["targetNode"]?.stringValue.flatMap { canvas.nodes[$0] }
        // The stored endpoints are a cache that goes stale when a shape moves,
        // so prefer re-deriving them from the anchored node.
        guard let start = anchorPoint(node["sourceAnchor"], on: source) ?? point(node["start"]),
              let end = anchorPoint(node["targetAnchor"], on: target) ?? point(node["end"])
        else { return [] }
        guard node["presentation"]?.stringValue != "straight",
              let from = anchorNormal(node["sourceAnchor"]),
              let into = anchorNormal(node["targetAnchor"])
        else { return dedupe([start, end]) }

        let exit = (x: start.x + from.x * connectorStub, y: start.y + from.y * connectorStub)
        let entry = (x: end.x + into.x * connectorStub, y: end.y + into.y * connectorStub)
        var corners: [(x: Double, y: Double)] = []
        if from.x != 0, into.x != 0 {
            let x = (exit.x + entry.x) / 2
            corners = [(x, exit.y), (x, entry.y)]
        } else if from.y != 0, into.y != 0 {
            let y = (exit.y + entry.y) / 2
            corners = [(exit.x, y), (entry.x, y)]
        } else if from.x != 0 {
            corners = [(entry.x, exit.y)]
        } else {
            corners = [(exit.x, entry.y)]
        }
        return dedupe([start, exit] + corners + [entry, end])
    }

    private static func anchorPoint(_ anchor: JSONValue?,
                                    on node: JSONValue?) -> (x: Double, y: Double)? {
        guard let node, let box = box(of: node),
              let left = number(anchor?["left"]), let top = number(anchor?["top"])
        else { return nil }
        return (box.minX + left * box.width, box.minY + top * box.height)
    }

    /// Anchors are fractions of the node box; `{left: 1, top: 0.5}` is the
    /// middle of the right edge, so the outward normal is `(1, 0)`.
    private static func anchorNormal(_ anchor: JSONValue?) -> (x: Double, y: Double)? {
        guard let left = number(anchor?["left"]), let top = number(anchor?["top"]) else {
            return nil
        }
        if left == 0 { return (-1, 0) }
        if left == 1 { return (1, 0) }
        if top == 0 { return (0, -1) }
        if top == 1 { return (0, 1) }
        return nil
    }

    // MARK: - Paths

    private static func dedupe(_ points: [(x: Double, y: Double)]) -> [(x: Double, y: Double)] {
        points.reduce(into: []) { result, point in
            guard let last = result.last else { return result.append(point) }
            if abs(last.x - point.x) > 0.01 || abs(last.y - point.y) > 0.01 {
                result.append(point)
            }
        }
    }

    /// Freehand strokes are sampled sparsely, so joining the samples with
    /// straight segments looks visibly angular next to Confluence's rendering.
    /// Curving through the segment midpoints reproduces the smoothed stroke.
    private static func smoothPath(_ points: [(x: Double, y: Double)]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        var d = "M \(f(first.x)) \(f(first.y))"
        guard points.count > 2 else { return d + " L \(f(last.x)) \(f(last.y))" }
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            d += " Q \(f(control.x)) \(f(control.y))"
            d += " \(f((control.x + next.x) / 2)) \(f((control.y + next.y) / 2))"
        }
        return d + " L \(f(last.x)) \(f(last.y))"
    }

    private static func path(through points: [(x: Double, y: Double)],
                             cornerRadius: Double) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        var d = "M \(f(first.x)) \(f(first.y))"
        guard points.count > 2, cornerRadius > 0 else {
            return d + " L \(f(last.x)) \(f(last.y))"
        }
        for index in 1..<(points.count - 1) {
            let corner = points[index]
            let entry = shifted(corner, toward: points[index - 1], by: cornerRadius)
            let exit = shifted(corner, toward: points[index + 1], by: cornerRadius)
            d += " L \(f(entry.x)) \(f(entry.y))"
            d += " Q \(f(corner.x)) \(f(corner.y)) \(f(exit.x)) \(f(exit.y))"
        }
        return d + " L \(f(last.x)) \(f(last.y))"
    }

    private static func shifted(_ origin: (x: Double, y: Double),
                                toward target: (x: Double, y: Double),
                                by distance: Double) -> (x: Double, y: Double) {
        let dx = target.x - origin.x, dy = target.y - origin.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return origin }
        let step = min(distance, length / 2) / length
        return (origin.x + dx * step, origin.y + dy * step)
    }

    private static func rotation(_ node: JSONValue, around box: Rect) -> String {
        guard let degrees = number(node["rotation"]), degrees != 0 else { return "" }
        return " transform=\"rotate(\(f(degrees)) \(f(box.midX)) \(f(box.midY)))\""
    }

    private static func strokeWidth(_ node: JSONValue) -> Double {
        switch node["stroke"]?.stringValue {
        case "small": return 2
        case "large": return 6
        default: return 4
        }
    }

    // MARK: - Text

    /// Wraps on measured advance width because CJK glyphs are twice as wide as
    /// Latin ones and sticky notes are narrow.
    private static func wrap(_ text: String, within width: Double, fontSize: Double) -> [String] {
        let limit = max(width, fontSize) / fontSize
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var current = ""
            var advance = 0.0
            for character in paragraph {
                let step = self.advance(of: character)
                if advance + step > limit, !current.isEmpty {
                    lines.append(current)
                    current = ""
                    advance = 0
                }
                current.append(character)
                advance += step
            }
            lines.append(current)
        }
        return lines
    }

    private static func advance(of character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first else { return 0.55 }
        return scalar.value >= 0x1100 ? 1.0 : 0.55
    }

    // MARK: - Colours

    /// Design tokens look like `palette.light.yellow.200`; they are approximated
    /// in HSL because the exact token values are not published with the payload.
    static func color(_ token: String?, fallback: String) -> String {
        guard let token else { return fallback }
        let parts = token.split(separator: ".")
        guard parts.count >= 4, parts[0] == "palette" else { return fallback }
        let tone = parts[1], hue = String(parts[2]), shade = Double(parts[3]) ?? 300
        guard let base = hues[hue] else { return fallback }
        let pastel = tone == "light"
        let lightness = (pastel ? 0.84 : 0.42) - (shade - 200) / 1000 * 0.28
        let saturation = base.saturation * (pastel ? 1.0 : 0.85)
        return hex(hue: base.degrees, saturation: saturation,
                   lightness: min(max(lightness, 0.06), 0.96))
    }

    private static let hues: [String: (degrees: Double, saturation: Double)] = [
        "red": (4, 0.72), "orange": (28, 0.85), "yellow": (48, 0.85), "lime": (80, 0.6),
        "green": (150, 0.6), "teal": (185, 0.6), "blue": (212, 0.8), "purple": (270, 0.5),
        "magenta": (320, 0.6), "pink": (338, 0.7), "gray": (215, 0.08), "grey": (215, 0.08),
    ]

    private static func hex(hue: Double, saturation: Double, lightness: Double) -> String {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hue {
        case ..<60:   (r, g, b) = (c, x, 0)
        case ..<120:  (r, g, b) = (x, c, 0)
        case ..<180:  (r, g, b) = (0, c, x)
        case ..<240:  (r, g, b) = (0, x, c)
        case ..<300:  (r, g, b) = (x, 0, c)
        default:      (r, g, b) = (c, 0, x)
        }
        let channels = [r, g, b].map { UInt8(((($0 + m) * 255).rounded()).clamped(0, 255)) }
        return "#" + channels.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private static func kind(of node: JSONValue) -> String {
        node["type"]?.stringValue ?? ""
    }

    private static func zIndex(_ node: JSONValue) -> Double {
        number(node["zIndex"]) ?? 0
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let value) = value ?? .null else { return nil }
        return value
    }

    private static func f(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? { objectValue?[key] }
}

private extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double { min(max(self, lower), upper) }
}
