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

    func testInlineImageDoesNotSplitParagraph() {
        // A raw <img> inside a paragraph must stay inline, not force a block
        // break that splits the surrounding text into separate paragraphs.
        let html = #"<p>Before <img src="icon.png" alt="i"/> after</p>"#
        let md = StorageFormatRenderer.render(html)
        XCTAssertTrue(md.contains("Before ![i](icon.png) after"), "inline image split the paragraph: \(md)")
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

    func testBlockInsideListItemDoesNotBreakList() {
        // A block-level element inside a list item must not inject a blank line
        // that emits an unindented continuation (e.g. `## Heading`) and
        // terminates the list item.
        let md = StorageFormatRenderer.render("<ul><li>intro<h2>Sub</h2></li><li>two</li></ul>")
        XCTAssertFalse(md.contains("\n## Sub"), "heading leaked as an unindented line, breaking the list: \(md)")
        XCTAssertTrue(md.contains("- two"), "list item after a block-containing item was lost: \(md)")
    }

    func testTopLevelBlockBoundaryStillEnforced() {
        // The top-level image→heading boundary fix must remain in effect.
        let md = StorageFormatRenderer.render(#"<img src="a.png" /><h2>H</h2>"#)
        XCTAssertTrue(md.contains("\n## H"), "expected blank line before top-level heading: \(md)")
    }

    func testAcImageInsideListItemDoesNotBreakList() {
        // `ac:image` must not append a blank-line boundary inside a list item,
        // which would leak a following block out of the list.
        let md = StorageFormatRenderer.render(
            #"<ul><li><ac:image><ri:attachment ri:filename="d.png" /></ac:image><h2>Sub</h2></li><li>two</li></ul>"#
        )
        XCTAssertFalse(md.contains("\n## Sub"), "heading leaked out of the list item: \(md)")
        XCTAssertTrue(md.contains("- two"), "list item after an image-containing item was lost: \(md)")
    }

    func testAcImageAtTopLevelStillSeparatesFollowingBlock() {
        let md = StorageFormatRenderer.render(
            #"<ac:image><ri:attachment ri:filename="d.png" /></ac:image><h2>Next</h2>"#
        )
        XCTAssertTrue(md.contains("\n## Next"), "expected blank line before top-level heading: \(md)")
    }

    func testRenderBodyNilIsEmpty() {
        XCTAssertEqual(ConfluenceContentRenderer.renderBody(nil), "")
    }
}
