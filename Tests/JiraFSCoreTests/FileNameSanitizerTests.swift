import XCTest
import AtlassianCore
@testable import JiraFSCore

final class FileNameSanitizerTests: XCTestCase {
    func testReplacesSlashes() {
        XCTAssertEqual(FileNameSanitizer.sanitize("a/b\\c"), "a_b_c")
    }

    func testReplacesControlCharacters() {
        XCTAssertEqual(FileNameSanitizer.sanitize("ab\u{0001}c"), "ab_c")
    }

    func testEscapesDots() {
        XCTAssertEqual(FileNameSanitizer.sanitize(".."), ".._")
        XCTAssertEqual(FileNameSanitizer.sanitize("."), "._")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(FileNameSanitizer.sanitize("  foo  "), "foo")
    }

    func testEmptyBecomesUnderscore() {
        XCTAssertEqual(FileNameSanitizer.sanitize(""), "_")
        XCTAssertEqual(FileNameSanitizer.sanitize(" . "), "_")
    }

    func testDeduplicatePreservesExtension() {
        var taken: Set<String> = ["foo.txt"]
        XCTAssertEqual(FileNameSanitizer.deduplicate("foo.txt", taken: &taken), "foo (2).txt")
        XCTAssertEqual(FileNameSanitizer.deduplicate("foo.txt", taken: &taken), "foo (3).txt")
    }
}
