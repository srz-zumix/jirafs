import XCTest
@testable import JiraFSCore

final class CacheManagerTests: XCTestCase {
    func testHitAndMiss() async {
        let cache = CacheManager()
        await cache.set("k", value: 42, ttl: 60)
        let hit: Int? = await cache.get("k", as: Int.self)
        XCTAssertEqual(hit, 42)
        let miss: String? = await cache.get("missing", as: String.self)
        XCTAssertNil(miss)
    }

    func testTTLExpiry() async {
        let cache = CacheManager()
        await cache.set("k", value: "v", ttl: -1)
        let v: String? = await cache.get("k", as: String.self)
        XCTAssertNil(v)
    }

    func testSynchronizeClears() async {
        let cache = CacheManager()
        await cache.set("k", value: 1, ttl: 60)
        await cache.synchronize()
        let v: Int? = await cache.get("k", as: Int.self)
        XCTAssertNil(v)
    }
}
