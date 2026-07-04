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

    func testViewURLWithoutQueryRewrittenToLocalPath() {
        let attachments = [ConfluenceAttachment(id: "a1", title: "image.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="/download/attachments/123/image.png" alt="x">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(html.contains(#"src="Page/.attachments/image.png""#))
        XCTAssertFalse(html.contains("/download/attachments/"))
    }

    func testExternalURLPreserved() {
        // An external URL whose basename matches a page attachment must NOT be
        // rewritten: only Confluence `/download/` URLs are repointed locally.
        let attachments = [ConfluenceAttachment(id: "a1", title: "x.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="https://example.com/x.png">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(html.contains("https://example.com/x.png"))
        XCTAssertFalse(html.contains(".attachments/x.png"))
    }

    func testMarkdownExternalURLPreserved() {
        let attachments = [ConfluenceAttachment(id: "a1", title: "x.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="https://example.com/x.png">"#, format: .view)
        )
        let md = String(decoding: PageFileBuilder.body(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(md.contains("(https://example.com/x.png)"))
        XCTAssertFalse(md.contains("](.attachments/x.png)"))
    }

    func testViewURLWithEncodedFilenameRewritten() {
        let attachments = [ConfluenceAttachment(id: "a1", title: "my file.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="/download/attachments/123/my%20file.png" alt="x">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(html.contains(#"src="Page/.attachments/my%20file.png""#))
        XCTAssertFalse(html.contains("/download/attachments/"))
    }

    func testHTMLFolderNameOverrideUsedForAttachments() {
        // When two titles sanitize to the same stem, the deduplicated on-disk
        // folder name must be used for the sibling `.attachments/` path.
        let page = ConfluencePage(
            id: "1", title: "My Page",
            body: body(#"<ac:image><ri:attachment ri:filename="diagram.png" /></ac:image>"#, format: .storage)
        )
        let html = String(decoding: PageFileBuilder.html(page, folderName: "My Page (2)"), as: UTF8.self)
        XCTAssertTrue(html.contains(#"src="My%20Page%20(2)/.attachments/diagram.png""#))
    }

    func testThumbnailURLRewritten() {
        let attachments = [ConfluenceAttachment(id: "a1", title: "image.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="/download/thumbnails/123/image.png" alt="x">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(html.contains(#"src="Page/.attachments/image.png""#))
        XCTAssertFalse(html.contains("/download/thumbnails/"))
    }

    func testDownloadFilesURLNotRewritten() {
        // A non-attachment `/download/files/` path must not be rewritten just
        // because it ends with a known attachment filename.
        let attachments = [ConfluenceAttachment(id: "a1", title: "image.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="https://ext.example.com/download/files/image.png">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(html.contains("https://ext.example.com/download/files/image.png"))
        XCTAssertFalse(html.contains(".attachments/image.png"))
    }

    func testStorageDuplicateAttachmentNamesDeduplicated() {
        // Two attachments whose titles sanitize to the same name get ` (2)` on
        // disk; the second storage reference must resolve to that entry.
        let attachments = [
            ConfluenceAttachment(id: "a1", title: "a/b.png"),
            ConfluenceAttachment(id: "a2", title: "a\\b.png"),
        ]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="/download/attachments/1/a%5Cb.png">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page, attachments: attachments), as: UTF8.self)
        // Both titles sanitize to `a_b.png`; the second listing entry is `a_b (2).png`.
        XCTAssertTrue(html.contains(#"src="Page/.attachments/a_b%20(2).png""#), html)
    }

    func testViewURLWithEncodedSlashRewritten() {
        // An attachment whose title contains `/` appears as `%2F` in Confluence
        // download URLs; the rewrite must still match and repoint it locally.
        let attachments = [ConfluenceAttachment(id: "a1", title: "a/b.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="/download/attachments/1/a%2Fb.png" alt="x">"#, format: .view)
        )
        let html = String(decoding: PageFileBuilder.html(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(html.contains(#"src="Page/.attachments/a_b.png""#), html)
        XCTAssertFalse(html.contains("/download/attachments/"))
    }

    func testMarkdownStorageAttachmentSanitized() {
        // Storage `](attachments/X)` where X needs sanitizing resolves to the
        // sanitized on-disk name.
        let attachments = [ConfluenceAttachment(id: "a1", title: "a/b.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<ac:link><ri:attachment ri:filename="a/b.png" /></ac:link>"#, format: .storage)
        )
        let md = String(decoding: PageFileBuilder.body(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(md.contains("](.attachments/a_b.png)"), md)
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

    func testMarkdownViewExternalURLWithAttachmentNameNotRewritten() {
        let attachments = [ConfluenceAttachment(id: "a1", title: "image.png")]
        let page = ConfluencePage(
            id: "1", title: "Page",
            body: body(#"<img src="https://cdn.example.com/assets/image.png" alt="x">"#, format: .view)
        )
        let md = String(decoding: PageFileBuilder.body(page, attachments: attachments), as: UTF8.self)
        XCTAssertTrue(md.contains("https://cdn.example.com/assets/image.png"))
        XCTAssertFalse(md.contains("](.attachments/image.png)"))
    }
}
