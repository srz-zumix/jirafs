import XCTest
import CryptoKit
import AtlassianCore
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

    // MARK: - Disk cache

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachemgr-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    func testDiskRoundTripWithKey() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let cache = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: key)
        await cache.set("k", value: "hello", ttl: 60)

        // Survives a memory wipe: re-read from disk via a fresh manager.
        let reopened = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: key)
        let v: String? = await reopened.get("k", as: String.self)
        XCTAssertEqual(v, "hello")
    }

    func testNoPlaintextKeyOnDisk() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let cache = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: key)
        await cache.set("k", value: "secret", ttl: 60)

        // The key must never be persisted next to the ciphertext.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(".cache.key").path))
        // Cached payload must not be readable as plaintext on disk.
        let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        for name in files ?? [] where name.hasSuffix(".cache") {
            let data = try? Data(contentsOf: dir.appendingPathComponent(name))
            let asString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(asString.contains("secret"))
        }
    }

    func testMissingKeyFallsBackToMemoryOnly() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // diskEnabled but no key → memory-only, no files written.
        let cache = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: nil)
        await cache.set("k", value: "v", ttl: 60)
        let mem: String? = await cache.get("k", as: String.self)
        XCTAssertEqual(mem, "v")

        let reopened = CacheManager(diskEnabled: true, cachesDir: dir,
                                    encryptionKey: SymmetricKey(size: .bits256))
        let disk: String? = await reopened.get("k", as: String.self)
        XCTAssertNil(disk)
    }

    func testLegacyPlaintextKeyFileRemoved() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent(".cache.key")
        try? Data(repeating: 0xAB, count: 32).write(to: legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))

        _ = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: SymmetricKey(size: .bits256))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLegacyPlaintextKeyFileRemovedOnMemoryFallback() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent(".cache.key")
        try? Data(repeating: 0xCD, count: 32).write(to: legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))

        // Disk requested but no key → memory-only fallback. The sensitive legacy
        // key file must still be purged.
        _ = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testEvictionPurgesUndecryptableOrphans() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A .cache file from an old/foreign key cannot be decrypted by us.
        let orphan = dir.appendingPathComponent("deadbeef.cache")
        try? Data(repeating: 0x01, count: 64).write(to: orphan)

        let cache = CacheManager(diskEnabled: true, cachesDir: dir,
                                 encryptionKey: SymmetricKey(size: .bits256))
        await cache.set("k", value: "fresh", ttl: 60)
        await cache.evictExpiredDiskEntries()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                       "undecryptable orphan should be purged")
        // Our own fresh entry must remain.
        let v: String? = await cache.get("k", as: String.self)
        XCTAssertEqual(v, "fresh")
    }
}
