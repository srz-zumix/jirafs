import XCTest
@testable import JiraFSCore

final class CacheTTLConfigTests: XCTestCase {
    private func make(refreshInterval: TimeInterval, issues: TimeInterval) -> Configuration.CacheTTLConfig {
        Configuration.CacheTTLConfig(
            projects: 300, issues: issues, issueDetail: 600,
            attachments: 600, attachmentBinary: 1800,
            refreshInterval: refreshInterval
        )
    }

    func testNegativeDisablesPolling() {
        let c = make(refreshInterval: -1, issues: 600)
        XCTAssertNil(c.periodicRefreshInterval(minimum: 1, maximum: 86_400))
    }

    func testZeroDerivesFromIssuesTTL() {
        let c = make(refreshInterval: 0, issues: 600)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 600)
    }

    func testZeroWithDisabledCacheDisablesPolling() {
        let c = make(refreshInterval: 0, issues: 0)
        XCTAssertNil(c.periodicRefreshInterval(minimum: 1, maximum: 86_400))
    }

    func testPositiveOverridesTTL() {
        let c = make(refreshInterval: 30, issues: 600)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 30)
    }

    func testClampedToMinimum() {
        let c = make(refreshInterval: 0.1, issues: 600)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 1)
    }

    func testClampedToMaximum() {
        let c = make(refreshInterval: 999_999, issues: 600)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 86_400)
    }

    func testDerivedTTLClampedToMaximum() {
        let c = make(refreshInterval: 0, issues: 999_999)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 86_400)
    }

    func testNonFiniteIntervalDisablesPolling() {
        XCTAssertNil(make(refreshInterval: .infinity, issues: 600).periodicRefreshInterval(minimum: 1, maximum: 86_400))
        XCTAssertNil(make(refreshInterval: .nan, issues: 600).periodicRefreshInterval(minimum: 1, maximum: 86_400))
    }

    func testNonFiniteDerivedTTLDisablesPolling() {
        let c = make(refreshInterval: 0, issues: .infinity)
        XCTAssertNil(c.periodicRefreshInterval(minimum: 1, maximum: 86_400))
    }
}
