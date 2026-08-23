import XCTest
@testable import ConfluenceFSCore

final class WhiteboardSVGRendererTests: XCTestCase {
    /// Mirrors a real `getTeamworkGraphObject` response: MCP envelope →
    /// `bodyValue` canvas string → per-node ADF string.
    private func payload(nodes: String, edges: String = "") -> String {
        let canvas = #"{"version":"2024-05-20_ALPHA","type":"whiteboard","nodes":{\#(nodes)},"edges":{\#(edges)}}"#
        let escaped = canvas
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"data":{"data":{"objects":[{"type":"ConfluenceWhiteboard","raw":{"bodyValue":"\#(escaped)"}}]}},"statusCode":200}"#
    }

    private func sticky(id: String, text: String, x: Double, y: Double) -> String {
        let adf = #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"\#(text)"}]}]}"#
        let escaped = adf.replacingOccurrences(of: "\"", with: "\\\"")
        return #""\#(id)":{"id":"\#(id)","type":"sticky","zIndex":1,"geometry":{"position":{"x":\#(x),"y":\#(y)},"size":{"x":144,"y":144}},"color":"palette.light.yellow.200","text":"\#(escaped)"}"#
    }

    func testDrawsStickyRectangleAndText() throws {
        let svg = try XCTUnwrap(
            WhiteboardSVGRenderer.render(payload(nodes: sticky(id: "a", text: "note", x: 0, y: 0)),
                                         title: "Board"))

        // position is the node centre, so a 144² sticky at (0,0) spans -72…72.
        XCTAssertTrue(svg.contains(#"<rect x="-72" y="-72" width="144" height="144""#), svg)
        XCTAssertTrue(svg.contains(">note</tspan>"), svg)
        XCTAssertTrue(svg.contains("<title>Board</title>"), svg)
    }

    func testViewBoxCoversAllNodesWithPadding() throws {
        let json = payload(nodes: [
            sticky(id: "a", text: "one", x: 0, y: 0),
            sticky(id: "b", text: "two", x: 200, y: 100),
        ].joined(separator: ","))
        let svg = try XCTUnwrap(WhiteboardSVGRenderer.render(json, title: "Board"))

        // -72-48 … 272+48 horizontally, -72-48 … 172+48 vertically.
        XCTAssertTrue(svg.contains(#"viewBox="-120 -120 440 340""#), svg)
    }

    func testDrawsFreehandStrokeFromAbsolutePoints() throws {
        let drawing = #""d":{"id":"d","type":"drawing","zIndex":2,"stroke":"large","color":"palette.dark.gray.300","legacyGeometry":{"position":{"x":5,"y":5},"size":{"x":10,"y":10}},"points":[{"0":0,"1":0},{"0":10,"1":10}]}"#
        let svg = try XCTUnwrap(WhiteboardSVGRenderer.render(payload(nodes: drawing), title: "B"))

        XCTAssertTrue(svg.contains(#"<path d="M 0 0 L 10 10""#), svg)
        XCTAssertTrue(svg.contains(#"stroke-width="6""#), svg)
    }

    func testFreehandStrokeIsSmoothedThroughSegmentMidpoints() throws {
        let drawing = #""d":{"id":"d","type":"drawing","zIndex":2,"stroke":"small","legacyGeometry":{"position":{"x":10,"y":5},"size":{"x":20,"y":10}},"points":[{"0":0,"1":0},{"0":10,"1":10},{"0":20,"1":0}]}"#
        let svg = try XCTUnwrap(WhiteboardSVGRenderer.render(payload(nodes: drawing), title: "B"))

        // Curves through (10,10) to the midpoint of the next segment, then closes.
        XCTAssertTrue(svg.contains(#"<path d="M 0 0 Q 10 10 15 5 L 20 0""#), svg)
    }

    func testDrawsConnectorWithArrowMarker() throws {
        let connector = #""c":{"id":"c","type":"connector","zIndex":3,"stroke":"small","endCap":"arrow","start":{"x":0,"y":0},"end":{"x":50,"y":0}}"#
        let svg = try XCTUnwrap(WhiteboardSVGRenderer.render(payload(nodes: connector), title: "B"))

        XCTAssertTrue(svg.contains(#"<marker id="arrow""#), svg)
        XCTAssertTrue(svg.contains(#"marker-end="url(#arrow)""#), svg)
        // Without anchors there is nothing to route around, so it stays straight.
        XCTAssertTrue(svg.contains(#"<path d="M 0 0 L 50 0""#), svg)
    }

    func testDynamicConnectorIsRoutedOrthogonally() throws {
        let connector = #""c":{"id":"c","type":"connector","zIndex":3,"stroke":"small","endCap":"arrow","presentation":"dynamic","sourceAnchor":{"left":1,"top":0.5},"targetAnchor":{"left":0.5,"top":0},"start":{"x":0,"y":0},"end":{"x":200,"y":100}}"#
        let svg = try XCTUnwrap(WhiteboardSVGRenderer.render(payload(nodes: connector), title: "B"))

        // Leaves the source rightwards (stub 24), turns at x=200, enters the
        // target from above; corners are rounded with quadratic segments.
        XCTAssertTrue(svg.contains(#"<path d="M 0 0 L 16 0 Q 24 0 32 0"#), svg)
        XCTAssertTrue(svg.contains("L 192 0 Q 200 0 200 8"), svg)
        XCTAssertTrue(svg.contains("L 200 100\""), svg)
        // The route bounds drive the viewBox, so the elbow must be inside it.
        XCTAssertTrue(svg.contains(#"viewBox="-48 -48 296 196""#), svg)
    }

    func testConnectorEndpointsComeFromTheAnchoredNodesNotTheStoredCache() throws {
        let connector = #""c":{"id":"c","type":"connector","zIndex":3,"stroke":"small","presentation":"dynamic","sourceAnchor":{"left":1,"top":0.5},"targetAnchor":{"left":0,"top":0.5},"start":{"x":999,"y":999},"end":{"x":999,"y":999}}"#
        let edges = #""c":{"id":"c","type":"association","sourceNode":"a","targetNode":"b"}"#
        let json = payload(
            nodes: [sticky(id: "a", text: "one", x: 0, y: 0),
                    sticky(id: "b", text: "two", x: 400, y: 0),
                    connector].joined(separator: ","),
            edges: edges)
        let svg = try XCTUnwrap(WhiteboardSVGRenderer.render(json, title: "B"))

        // Right edge of "a" (72, 0) to the left edge of "b" (328, 0), not (999, 999).
        XCTAssertTrue(svg.contains(#"<path d="M 72 0"#), svg)
        XCTAssertTrue(svg.contains("L 328 0\""), svg)
        XCTAssertFalse(svg.contains("999"), svg)
    }

    func testImageBecomesPlaceholderLabelledWithItsMediaMetadata() throws {
        let image = #""i":{"id":"i","type":"image","zIndex":4,"mimeType":"image/png","fileId":"8a8183d3-34c6-4ccf-806d-d02bcd06b747","nativeSize":{"x":1952,"y":2176},"legacyGeometry":{"position":{"x":0,"y":0},"size":{"x":100,"y":80}}}"#
        let svg = try XCTUnwrap(WhiteboardSVGRenderer.render(payload(nodes: image), title: "B"))

        XCTAssertTrue(svg.contains(#"stroke-dasharray="6 4""#), svg)
        XCTAssertTrue(svg.contains(">image/png</tspan>"), svg)
        XCTAssertTrue(svg.contains(">1952 × 2176</tspan>"), svg)
        XCTAssertTrue(svg.contains(">8a8183d3</tspan>"), svg)
    }

    func testImagePlaceholderDropsLabelsThatWouldOverflowTheBox() throws {
        let image = #""i":{"id":"i","type":"image","zIndex":4,"mimeType":"image/png","fileId":"8a8183d3-34c6-4ccf-806d-d02bcd06b747","nativeSize":{"x":1952,"y":2176},"legacyGeometry":{"position":{"x":0,"y":0},"size":{"x":100,"y":20}}}"#
        let svg = try XCTUnwrap(WhiteboardSVGRenderer.render(payload(nodes: image), title: "B"))

        XCTAssertTrue(svg.contains(">image/png</tspan>"), svg)
        XCTAssertFalse(svg.contains("1952"), svg)
    }

    func testPaletteTokensBecomeHexColours() {
        XCTAssertEqual(WhiteboardSVGRenderer.color("palette.light.yellow.200", fallback: "#000000")
            .prefix(1), "#")
        XCTAssertEqual(WhiteboardSVGRenderer.color(nil, fallback: "#abcdef"), "#abcdef")
        XCTAssertEqual(WhiteboardSVGRenderer.color("unexpected", fallback: "#abcdef"), "#abcdef")
    }

    func testReturnsNilForUnexpectedPayload() {
        XCTAssertNil(WhiteboardSVGRenderer.render("not json", title: "B"))
        XCTAssertNil(WhiteboardSVGRenderer.render(payload(nodes: ""), title: "B"))
    }
}
