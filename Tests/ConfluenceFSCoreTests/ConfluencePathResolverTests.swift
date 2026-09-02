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
        XCTAssertEqual(children.map(\.name), [".space.json", "AGENTS.md", "pages"])
        XCTAssertEqual(ConfluencePathResolver.staticChild(name: "AGENTS.md", of: .space(key: "DOC")),
                       .spaceAgentsGuide(spaceKey: "DOC"))
    }

    func testPagesDirHasAgentsGuide() {
        let children = ConfluencePathResolver.childKinds(of: .pagesDir(spaceKey: "DOC"))
        XCTAssertEqual(children.map(\.name), ["AGENTS.md"])
        XCTAssertEqual(ConfluencePathResolver.staticChild(name: "AGENTS.md", of: .pagesDir(spaceKey: "DOC")),
                       .pagesAgentsGuide(spaceKey: "DOC"))
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
        XCTAssertTrue(ConfluenceNodeKind.folderDir(spaceKey: "D", folderId: "f1").isDirectory)
    }

    func testFolderDirHasNoStaticChildren() {
        let children = ConfluencePathResolver.childKinds(of: .folderDir(spaceKey: "DOC", folderId: "f1"))
        XCTAssertTrue(children.isEmpty, "folderDir has no static children — all content is dynamic")
    }

    func testFolderDirStaticChildResolvesNil() {
        XCTAssertNil(ConfluencePathResolver.staticChild(name: "SomePage", of: .folderDir(spaceKey: "DOC", folderId: "f1")))
    }
    func testWhiteboardDirIsDirectoryWithMetadata() {
        XCTAssertTrue(ConfluenceNodeKind.whiteboardDir(spaceKey: "D", whiteboardId: "w1").isDirectory)
        XCTAssertFalse(ConfluenceNodeKind.whiteboardMeta(spaceKey: "D", whiteboardId: "w1").isDirectory)
        let children = ConfluencePathResolver.childKinds(of: .whiteboardDir(spaceKey: "DOC", whiteboardId: "w1"))
        XCTAssertEqual(children.map(\.name), [".metadata.json"])
        XCTAssertEqual(ConfluencePathResolver.staticChild(name: ".metadata.json",
                                                         of: .whiteboardDir(spaceKey: "DOC", whiteboardId: "w1")),
                       .whiteboardMeta(spaceKey: "DOC", whiteboardId: "w1"))
        // Child pages / nested boards are dynamic → not resolvable statically.
        XCTAssertNil(ConfluencePathResolver.staticChild(name: "SomePage",
                                                       of: .whiteboardDir(spaceKey: "DOC", whiteboardId: "w1")))
    }

    func testDatabaseDirIsDirectoryWithMetadata() {
        XCTAssertTrue(ConfluenceNodeKind.databaseDir(spaceKey: "D", databaseId: "d1").isDirectory)
        XCTAssertFalse(ConfluenceNodeKind.databaseMeta(spaceKey: "D", databaseId: "d1").isDirectory)
        let children = ConfluencePathResolver.childKinds(of: .databaseDir(spaceKey: "DOC", databaseId: "d1"))
        XCTAssertEqual(children.map(\.name), [".metadata.json"])
        XCTAssertEqual(ConfluencePathResolver.staticChild(name: ".metadata.json",
                                                         of: .databaseDir(spaceKey: "DOC", databaseId: "d1")),
                       .databaseMeta(spaceKey: "DOC", databaseId: "d1"))
        // Child pages / nested databases are dynamic → not resolvable statically.
        XCTAssertNil(ConfluencePathResolver.staticChild(name: "SomePage",
                                                       of: .databaseDir(spaceKey: "DOC", databaseId: "d1")))
    }
}
