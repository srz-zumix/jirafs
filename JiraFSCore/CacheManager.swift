import Foundation

/// Async, TTL-based in-memory cache shared by the FSKit volume and clients.
///
/// Stores arbitrary `Sendable` values keyed by string. Expired entries are
/// returned as miss; `synchronize()` clears everything (called from
/// `FSVolume.synchronize`).
public actor CacheManager {
    private struct Entry {
        let value: any Sendable
        let expiresAt: Date
    }

    private var storage: [String: Entry] = [:]

    public init() {}

    public func get<T: Sendable>(_ key: String, as type: T.Type) -> T? {
        guard let entry = storage[key] else { return nil }
        if entry.expiresAt < Date() {
            storage.removeValue(forKey: key)
            return nil
        }
        return entry.value as? T
    }

    public func set<T: Sendable>(_ key: String, value: T, ttl: TimeInterval) {
        storage[key] = Entry(value: value, expiresAt: Date().addingTimeInterval(ttl))
    }

    public func remove(_ key: String) {
        storage.removeValue(forKey: key)
    }

    public func synchronize() {
        storage.removeAll()
    }
}
