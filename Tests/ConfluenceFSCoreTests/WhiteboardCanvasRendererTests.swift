import XCTest
@testable import ConfluenceFSCore

final class WhiteboardCanvasRendererTests: XCTestCase {
    /// Mirrors a real `getTeamworkGraphObject` response: MCP envelope →
    /// `bodyValue` canvas string → per-node ADF string.
    private func payload(nodes: String) -> String {
        let canvas = #"{"version":"2024-05-20_ALPHA","type":"whiteboard","nodes":{\#(nodes)},"edges":{}}"#
        let escaped = canvas
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"data":{"data":{"objects":[{"type":"ConfluenceWhiteboard","raw":{"bodyValue":"\#(escaped)"}}]}},"statusCode":200}"#
    }

    private func sticky(id: String, text: String, x: Double, y: Double) -> String {
        let adf = #"{"version":1,"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"\#(text)"}]}]}"#
        let escaped = adf.replacingOccurrences(of: "\"", with: "\\\"")
        return #""\#(id)":{"id":"\#(id)","type":"sticky","geometry":{"position":{"x":\#(x),"y":\#(y)},"size":{"x":144,"y":144}},"text":"\#(escaped)"}"#
    }

    func testRendersStickyNotesInReadingOrder() {
        let json = payload(nodes: [
            sticky(id: "b", text: "second", x: 0, y: 100),
            sticky(id: "a", text: "first", x: -50, y: -10),
            sticky(id: "c", text: "third", x: 200, y: 100),
        ].joined(separator: ","))

        XCTAssertEqual(WhiteboardCanvasRenderer.render(json), "- first\n- second\n- third")
    }

    func testSummarizesNodesWithoutText() {
        let shape = #""s":{"id":"s","type":"shape","geometry":{"position":{"x":0,"y":0}}}"#
        let json = payload(nodes: [sticky(id: "a", text: "note", x: 0, y: 50), shape].joined(separator: ","))

        XCTAssertEqual(WhiteboardCanvasRenderer.render(json),
                       "- note\n\n_Elements without text: shape × 1._")
    }

    func testReturnsNilForUnexpectedPayload() {
        XCTAssertNil(WhiteboardCanvasRenderer.render("not json"))
        XCTAssertNil(WhiteboardCanvasRenderer.render(#"{"data":{"data":{"objects":[]}}}"#))
        XCTAssertNil(WhiteboardCanvasRenderer.render(payload(nodes: "")))
    }
}
