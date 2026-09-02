import XCTest
@testable import ConfluenceFSCore

final class DatabaseCSVRendererTests: XCTestCase {
    /// The shape Rovo MCP actually returns: CRLF line endings and three
    /// blank-line-separated blocks (fields, views, entries).
    private let payload = """
        field_name,type,configuration\r
        Date,date,\r
        Notes,text,\r
        \r
        view_name,layout,filters,sorts,hidden_fields,is_default,is_current\r
        All entries,table,,,,true,true\r
        \r
        _id,Date,Notes\r
        1,2024/05/26,"camping, games"\r
        2,2024/05/27,plants\r
        """

    func testSectionsSplitOnBlankLines() {
        let sections = DatabaseCSVRenderer.sections(payload)
        XCTAssertEqual(sections.map(\.title), ["Fields", "Views", "Entries"])
        XCTAssertEqual(sections[0].rows.count, 2)
        XCTAssertEqual(sections[2].header, ["_id", "Date", "Notes"])
        // A quoted field keeps its embedded separator.
        XCTAssertEqual(sections[2].rows[0], ["1", "2024/05/26", "camping, games"])
    }

    func testRenderProducesOneTablePerSection() {
        let markdown = DatabaseCSVRenderer.render(payload)
        XCTAssertTrue(markdown.contains("## Fields"))
        XCTAssertTrue(markdown.contains("## Entries"))
        XCTAssertTrue(markdown.contains("| _id | Date | Notes |"))
        XCTAssertTrue(markdown.contains("| 1 | 2024/05/26 | camping, games |"))
    }

    func testQuoteEscapesAndEmbeddedNewlines() {
        let records = DatabaseCSVRenderer.records("a,\"say \"\"hi\"\"\",\"two\r\nlines\"\r\n")
        XCTAssertEqual(records, [["a", "say \"hi\"", "two\r\nlines"]])
        // A line break cannot survive inside a Markdown table cell.
        XCTAssertEqual(DatabaseCSVRenderer.escape("two\r\nlines"), "two<br>lines")
        XCTAssertEqual(DatabaseCSVRenderer.escape("a|b"), "a\\|b")
    }

    func testShortRowsArePaddedToHeaderWidth() {
        let section = DatabaseCSVRenderer.sections("a,b,c\r\n1\r\n")[0]
        XCTAssertTrue(DatabaseCSVRenderer.table(section).contains("| 1 |  |  |"))
    }

    func testUnparsablePayloadFallsBackToFencedBlock() {
        XCTAssertTrue(DatabaseCSVRenderer.render("").hasPrefix("```csv"))
    }
}
