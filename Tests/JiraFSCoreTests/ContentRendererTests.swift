import XCTest
@testable import JiraFSCore
import JiraAPI

final class ContentRendererTests: XCTestCase {
    func testWikiHeading() {
        let md = ContentRenderer.renderDescription(.string("h2. Hello"))
        XCTAssertTrue(md.contains("## Hello"))
    }

    func testWikiLink() {
        let md = ContentRenderer.renderDescription(.string("see [docs|https://example.com]"))
        XCTAssertTrue(md.contains("[docs](https://example.com)"))
    }

    func testWikiBoldRewrite() {
        let md = ContentRenderer.renderDescription(.string("*bold*"))
        XCTAssertTrue(md.contains("**bold**"))
    }

    func testADFParagraph() {
        let json: JSONValue = .object([
            "type": .string("doc"),
            "content": .array([
                .object([
                    "type": .string("paragraph"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("hi")])
                    ])
                ])
            ])
        ])
        let md = ContentRenderer.renderDescription(json)
        XCTAssertEqual(md.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }

    func testADFHeading() {
        let json: JSONValue = .object([
            "type": .string("doc"),
            "content": .array([
                .object([
                    "type": .string("heading"),
                    "attrs": .object(["level": .number(2)]),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("Title")])
                    ])
                ])
            ])
        ])
        let md = ContentRenderer.renderDescription(json)
        XCTAssertTrue(md.contains("## Title"))
    }

    func testADFLinkMark() {
        let json: JSONValue = .object([
            "type": .string("doc"),
            "content": .array([
                .object([
                    "type": .string("paragraph"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("here"),
                            "marks": .array([
                                .object([
                                    "type": .string("link"),
                                    "attrs": .object(["href": .string("https://x.test")])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        let md = ContentRenderer.renderDescription(json)
        XCTAssertTrue(md.contains("[here](https://x.test)"))
    }

    func testNullDescription() {
        XCTAssertEqual(ContentRenderer.renderDescription(nil), "")
        XCTAssertEqual(ContentRenderer.renderDescription(.null), "")
    }
}
