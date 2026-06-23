import XCTest
@testable import JiraFSCore

final class PathResolverTests: XCTestCase {
    func testRootHasProjectsAndConfig() {
        let kids = PathResolver.childKinds(of: .root)
        XCTAssertEqual(kids.map(\.name), ["projects", "AGENTS.md", ".jirafs", ".metadata_never_index"])
    }

    func testIssuesDirHasAgentsGuide() {
        let kids = PathResolver.childKinds(of: .issuesDir(project: "ABC"))
        XCTAssertEqual(kids.map(\.name), ["AGENTS.md"])
        XCTAssertEqual(kids.first?.kind, .issuesAgentsGuide(project: "ABC"))
    }

    func testProjectHasAgentsGuide() {
        let kids = PathResolver.childKinds(of: .project(key: "ABC"))
        XCTAssertEqual(kids.map(\.name), [".project.json", "AGENTS.md", "issues"])
        XCTAssertEqual(PathResolver.staticChild(name: "AGENTS.md", of: .project(key: "ABC")),
                       .projectAgentsGuide(project: "ABC"))
    }

    func testIssueChildren() {
        let kids = PathResolver.childKinds(of: .issue(key: "ABC-1"))
        XCTAssertEqual(kids.map(\.name), [
            "summary.txt", "description.md", "metadata.json", "comments", "attachments",
        ])
    }

    func testStaticChildResolves() {
        let kind = PathResolver.staticChild(name: "summary.txt", of: .issue(key: "X-1"))
        XCTAssertEqual(kind, .summary(issueKey: "X-1"))
    }

    func testStaticChildReturnsNilForUnknown() {
        XCTAssertNil(PathResolver.staticChild(name: "bogus", of: .issue(key: "X-1")))
    }
}
