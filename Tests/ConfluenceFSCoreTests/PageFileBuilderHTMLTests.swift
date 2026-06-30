import XCTest
@testable import ConfluenceFSCore
import ConfluenceAPI

final class PageFileBuilderHTMLTests: XCTestCase {
    private func body(_ value: String, format: ConfluenceBodyFormat) -> ConfluenceBody {
        ConfluenceBody(format: format, value: value)
    }

    func testStorageImageRewrittenToLocalPath() {
        let page = ConfluencePage(
            id: "1", title: "My Page",
            body: body(#"<ac:image><ri:attachment ri:filename="diagram.png" /></ac:image>"#, format: .storage)
        )
        let html = String(decoding: PageFileBuilder.html(page), as: UTF8.self)
        XCTAssertTrue(html.contains(#"<img src="My%20Page/.attachments/diagram.png" alt="diagram.png">"#))
        XCTAssertFalse(html.contains("ri:attachment"))
    }

    func testStorageLinkRewrittenToLocalPath() {
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<ac:link><ri:attachment ri:filename="report.pdf" /></ac:link>"#, format: .storage)
        )
        let html = String(decoding: PageFileBuilder.html(page), as: UTF8.self)
        XCTAssertTrue(html.contains(#"<a href="Page/.attachments/report.pdf">report.pdf</a>"#))
    }

    func testViewURLRewrittenToLocalPath() {
        let attachments = [ConfluenceAttachment(id: "a1", title: "image.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="/download/attachments/123/image.png?version=1" alt="x">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(html.contains(#"src="Page/.attachments/image.png""#))
        XCTAssertFalse(html.contains("/download/attachments/"))
    }

    func testExternalURLPreserved() {
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="https://example.com/x.png">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page), as: UTF8.self)
        XCTAssertTrue(html.contains("https://example.com/x.png"))
    }

    func testMarkdownAttachmentLinkRewritten() {
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<ac:link><ri:attachment ri:filename="report.pdf" /></ac:link>"#, format: .storage)
        )
        let md = String(decoding: PageFileBuilder.body(page), as: UTF8.self)
        XCTAssertTrue(md.contains("](.attachments/report.pdf)"))
        XCTAssertFalse(md.contains("](attachments/report.pdf)"))
    }

    func testMarkdownViewURLRewritten() {
        let attachments = [ConfluenceAttachment(id: "a1", title: "image.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="/download/attachments/123/image.png?v=1" alt="x">"#, format: .view)
        )
        let md = String(decoding: PageFileBuilder.body(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(md.contains("](.attachments/image.png)"))
        XCTAssertFalse(md.contains("/download/attachments/"))
    }
}
