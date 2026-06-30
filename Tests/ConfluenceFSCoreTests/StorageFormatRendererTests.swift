import XCTest
@testable import ConfluenceFSCore
import ConfluenceAPI

final class StorageFormatRendererTests: XCTestCase {
    func testHeadingAndParagraph() {
        let md = StorageFormatRenderer.render("<h1>Title</h1><p>Hello world</p>")
        XCTAssertTrue(md.contains("# Title"))
        XCTAssertTrue(md.contains("Hello world"))
    }

    func testInlineFormatting() {
        let md = StorageFormatRenderer.render("<p>This is <strong>bold</strong> and <em>italic</em>.</p>")
        XCTAssertTrue(md.contains("**bold**"))
        XCTAssertTrue(md.contains("*italic*"))
    }

    func testLink() {
        let md = StorageFormatRenderer.render(#"<p>See <a href="https://example.com">here</a></p>"#)
        XCTAssertTrue(md.contains("[here](https://example.com)"))
    }

    func testUnorderedList() {
        let md = StorageFormatRenderer.render("<ul><li>one</li><li>two</li></ul>")
        XCTAssertTrue(md.contains("- one"))
        XCTAssertTrue(md.contains("- two"))
    }

    func testEntities() {
        let md = StorageFormatRenderer.render("<p>a &amp; b &lt; c</p>")
        XCTAssertTrue(md.contains("a & b < c"))
    }

    func testRenderBodyDispatchesStorage() {
        let body = ConfluenceBody(format: .storage, value: "<p>Hi</p>")
        let md = ConfluenceContentRenderer.renderBody(body)
        XCTAssertTrue(md.contains("Hi"))
    }

    func testImageFollowedByHeadingHasBlankLine() {
        let xhtml = #"<ac:image><ri:attachment ri:filename="diagram.png" /></ac:image><h2>Next</h2>"#
        let md = StorageFormatRenderer.render(xhtml)
        XCTAssertFalse(md.contains(")## "), "heading must not be glued to image link: \(md)")
        XCTAssertTrue(md.contains("\n## Next"), "expected blank line before heading: \(md)")
    }

    func testViewImageFollowedByHeadingHasBlankLine() {
        let html = #"<img src="diagram.svg" /><h3>Modules</h3>"#
        let md = StorageFormatRenderer.render(html)
        XCTAssertFalse(md.contains(")### "), "heading must not be glued to image: \(md)")
        XCTAssertTrue(md.contains("\n### Modules"), "expected blank line before heading: \(md)")
    }

    func testRenderBodyDispatchesView() {
        // `.view` must route through StorageFormatRenderer (HTML), not the ADF path.
        let body = ConfluenceBody(format: .view, value: "<h1>Title</h1><p>Body</p>")
        let md = ConfluenceContentRenderer.renderBody(body)
        XCTAssertTrue(md.contains("# Title"), "expected heading markdown, got: \(md)")
        XCTAssertTrue(md.contains("Body"))
        XCTAssertFalse(md.contains(ConfluenceContentRenderer.rawFallbackMarker),
                       "view body should not hit the ADF raw fallback")
    }

    func testRenderBodyNilIsEmpty() {
        XCTAssertEqual(ConfluenceContentRenderer.renderBody(nil), "")
    }
}
