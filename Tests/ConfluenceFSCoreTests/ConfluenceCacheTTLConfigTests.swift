import XCTest
@testable import ConfluenceFSCore

final class ConfluenceCacheTTLConfigTests: XCTestCase {
    private func make(refreshInterval: TimeInterval, pages: TimeInterval) -> ConfluenceConfiguration.CacheTTLConfig {
        ConfluenceConfiguration.CacheTTLConfig(
            spaces: 300, pages: pages, pageDetail: 600,
            attachments: 600, attachmentBinary: 1800,
            refreshInterval: refreshInterval
        )
    }

    func testNegativeDisablesPolling() {
        let c = make(refreshInterval: -1, pages: 600)
        XCTAssertNil(c.periodicRefreshInterval(minimum: 1, maximum: 86_400))
    }

    func testZeroDerivesFromPagesTTL() {
        let c = make(refreshInterval: 0, pages: 600)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 600)
    }

    func testZeroWithDisabledCacheDisablesPolling() {
        let c = make(refreshInterval: 0, pages: 0)
        XCTAssertNil(c.periodicRefreshInterval(minimum: 1, maximum: 86_400))
    }

    func testPositiveOverridesTTL() {
        let c = make(refreshInterval: 30, pages: 600)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 30)
    }

    func testClampedToMinimum() {
        let c = make(refreshInterval: 0.1, pages: 600)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 1)
    }

    func testClampedToMaximum() {
        let c = make(refreshInterval: 999_999, pages: 600)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 86_400)
    }

    func testDerivedTTLClampedToMaximum() {
        let c = make(refreshInterval: 0, pages: 999_999)
        XCTAssertEqual(c.periodicRefreshInterval(minimum: 1, maximum: 86_400), 86_400)
    }

    func testNonFiniteIntervalDisablesPolling() {
        XCTAssertNil(make(refreshInterval: .infinity, pages: 600).periodicRefreshInterval(minimum: 1, maximum: 86_400))
        XCTAssertNil(make(refreshInterval: .nan, pages: 600).periodicRefreshInterval(minimum: 1, maximum: 86_400))
    }

    func testNonFiniteDerivedTTLDisablesPolling() {
        let c = make(refreshInterval: 0, pages: .infinity)
        XCTAssertNil(c.periodicRefreshInterval(minimum: 1, maximum: 86_400))
    }
}
