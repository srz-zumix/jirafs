import XCTest
@testable import ConfluenceFSCore

final class ConfluencePathResolverTests: XCTestCase {
    func testRootChildren() {
        let names = ConfluencePathResolver.childKinds(of: .root).map(\.name)
        XCTAssertEqual(names, ["spaces", "AGENTS.md", ".confluencefs", ".metadata_never_index"])
    }

    func testSpacesDirIsDynamic() {
        let keys = ["DOC", "TEAM"]
        let children = ConfluencePathResolver.childKinds(of: .spacesDir, spaceKeys: keys)
        XCTAssertEqual(children.map(\.name), keys)
        XCTAssertEqual(children.first?.kind, .space(key: "DOC"))
    }

    func testSpaceChildren() {
        let children = ConfluencePathResolver.childKinds(of: .space(key: "DOC"))
        XCTAssertEqual(children.map(\.name), [".space.json", "pages"])
    }

    func testPageDirStaticChildren() {
        let children = ConfluencePathResolver.childKinds(of: .pageDir(spaceKey: "DOC", pageId: "1"))
        XCTAssertEqual(children.map(\.name), ["page.md", ".metadata.json", ".labels.txt", ".comments", ".attachments"])
        XCTAssertEqual(children.first?.kind, .pageBody(spaceKey: "DOC", pageId: "1"))
    }

    func testStaticChildResolvesAndRejectsDynamic() {
        XCTAssertEqual(ConfluencePathResolver.staticChild(name: "pages", of: .space(key: "DOC")),
                       .pagesDir(spaceKey: "DOC"))
        // Page titles are dynamic → not resolvable statically.
        XCTAssertNil(ConfluencePathResolver.staticChild(name: "Some Page", of: .pagesDir(spaceKey: "DOC")))
    }

    func testDirectoryFlags() {
        XCTAssertTrue(ConfluenceNodeKind.pageDir(spaceKey: "D", pageId: "1").isDirectory)
        XCTAssertFalse(ConfluenceNodeKind.pageHtml(spaceKey: "D", pageId: "1").isDirectory)
        XCTAssertFalse(ConfluenceNodeKind.pageBody(spaceKey: "D", pageId: "1").isDirectory)
        XCTAssertTrue(ConfluenceNodeKind.commentsDir(spaceKey: "D", pageId: "1").isDirectory)
    }
}
