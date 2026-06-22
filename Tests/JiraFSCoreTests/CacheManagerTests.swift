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
        var foundCacheFile = false
        for name in files ?? [] where name.hasSuffix(".cache") {
            foundCacheFile = true
            let data = try? Data(contentsOf: dir.appendingPathComponent(name))
            let asString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertFalse(asString.contains("secret"))
        }
        XCTAssertTrue(foundCacheFile, "expected at least one .cache file to be written")
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

    func testDirCreationFailureFallsBackToMemoryOnly() async {
        let parent = makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Place a regular file where the cache directory should be so that
        // createDirectory fails → the cache must fall back to memory-only.
        let dir = parent.appendingPathComponent("cache")
        XCTAssertTrue(FileManager.default.createFile(atPath: dir.path, contents: Data("x".utf8)))

        let key = SymmetricKey(size: .bits256)
        let cache = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: key)
        await cache.set("k", value: "secret", ttl: 60)

        // Memory cache still works.
        let mem: String? = await cache.get("k", as: String.self)
        XCTAssertEqual(mem, "secret")

        // The path must remain the original file: nothing was persisted to disk.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue)
        let contents = try? Data(contentsOf: dir)
        XCTAssertEqual(contents, Data("x".utf8))
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

    /// Reads the single `.cache` file in `dir`, failing the test if there is not
    /// exactly one. Used to detect whether a write actually re-touched disk.
    private func soleCacheFileBytes(in dir: URL,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) -> Data? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".cache") }
        XCTAssertEqual(names.count, 1, "expected exactly one .cache file", file: file, line: line)
        guard let name = names.first else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    func testUnchangedContentSkipsDiskRewrite() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let cache = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: key)

        await cache.set("k", value: "same", ttl: 60)
        let firstBytes = soleCacheFileBytes(in: dir)
        XCTAssertNotNil(firstBytes)

        // Re-writing identical content must be a no-op on disk. AES-GCM uses a
        // fresh random nonce per seal, so an actual rewrite would change the
        // file bytes; identical bytes prove the write was skipped.
        await cache.set("k", value: "same", ttl: 60)
        XCTAssertEqual(soleCacheFileBytes(in: dir), firstBytes,
                       "identical content should not rewrite the cache file")

        // Changed content must rewrite, and the value must still round-trip.
        await cache.set("k", value: "different", ttl: 60)
        XCTAssertNotEqual(soleCacheFileBytes(in: dir), firstBytes,
                          "changed content should rewrite the cache file")
        let v: String? = await cache.get("k", as: String.self)
        XCTAssertEqual(v, "different")
    }

    func testRemoveAllowsRewriteOfSameContent() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let cache = CacheManager(diskEnabled: true, cachesDir: dir, encryptionKey: key)

        await cache.set("k", value: "same", ttl: 60)
        // Removing the entry must drop the fingerprint so an identical later
        // write recreates the file rather than being skipped as "unchanged".
        await cache.remove("k")
        let afterRemove = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".cache") }
        XCTAssertTrue(afterRemove.isEmpty, "remove should delete the cache file")

        await cache.set("k", value: "same", ttl: 60)
        XCTAssertNotNil(soleCacheFileBytes(in: dir), "identical content after remove should be re-written")
        let v: String? = await cache.get("k", as: String.self)
        XCTAssertEqual(v, "same")
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
