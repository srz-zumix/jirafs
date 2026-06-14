import Foundation
import AtlassianCore
import ConfluenceAPI

/// Runtime configuration for the Confluence file system (`.confluencefs/config.json`).
public struct ConfluenceConfiguration: Codable, Sendable, Equatable {
    public var version: Int
    public var instances: [InstanceEntry]
    public var cache: CacheTTLConfig
    public var pagination: Pagination

    public init(
        version: Int = 1,
        instances: [InstanceEntry] = [],
        cache: CacheTTLConfig = .default,
        pagination: Pagination = .default
    ) {
        self.version = version
        self.instances = instances
        self.cache = cache
        self.pagination = pagination
    }

    /// A resolved mount, derived by the host app from a (Server, Mount) pair and
    /// written into the extension's `config.json`. The extension routes a
    /// `confluence://<mountID>` URL to the matching entry.
    public struct InstanceEntry: Codable, Sendable, Equatable, Identifiable {
        /// Stable identifier for this mount. Embedded as the URL host in the
        /// `confluence://<mountID>` mount URL so the extension can route to it
        /// even when several mounts share the same server hostname.
        public var mountID: String
        /// Identifier of the server whose credentials (in the Keychain) this
        /// mount uses.
        public var serverID: String
        /// Display / volume name for this mount.
        public var name: String
        public var type: ConfluenceEdition
        public var url: URL
        public var auth: AuthEntry
        public var mountPath: String?
        /// Space keys to expose. `nil` means all spaces; a non-empty array limits
        /// the file system to only those keys (case-insensitive).
        public var allowedSpaceKeys: [String]?
        public var diskCache: Bool
        /// When `true`, each page exposes a sibling `{Title}.html` file.
        public var htmlView: Bool
        /// When `true`, archived pages are included in directory listings.
        /// Defaults to `false` (only current/active pages are shown).
        public var includeArchived: Bool
        /// When `false` (default), pages with any user/group restriction (read or
        /// update) are excluded from directory listings.
        public var includeRestricted: Bool
        /// When `true`, this instance is automatically mounted when the app launches.
        /// Defaults to `false`.
        public var autoMount: Bool

        public var id: String { mountID }

        public var effectiveMountPath: String {
            let raw = mountPath ?? "~/confluencefs/\(name)"
            return (raw as NSString).expandingTildeInPath
        }

        public init(mountID: String, serverID: String, name: String, type: ConfluenceEdition,
                    url: URL, auth: AuthEntry,
                    mountPath: String? = nil, allowedSpaceKeys: [String]? = nil,
                    diskCache: Bool = true, htmlView: Bool = false, includeArchived: Bool = false,
                    includeRestricted: Bool = false, autoMount: Bool = false) {
            self.mountID = mountID
            self.serverID = serverID
            self.name = name
            self.type = type
            self.url = url
            self.auth = auth
            self.mountPath = mountPath
            self.allowedSpaceKeys = allowedSpaceKeys
            self.diskCache = diskCache
            self.htmlView = htmlView
            self.includeArchived = includeArchived
            self.includeRestricted = includeRestricted
            self.autoMount = autoMount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name            = try c.decode(String.self, forKey: .name)
            mountID         = try c.decodeIfPresent(String.self, forKey: .mountID) ?? name
            serverID        = try c.decodeIfPresent(String.self, forKey: .serverID) ?? ""
            type            = try c.decode(ConfluenceEdition.self, forKey: .type)
            url             = try c.decode(URL.self, forKey: .url)
            auth            = try c.decode(AuthEntry.self, forKey: .auth)
            mountPath       = try c.decodeIfPresent(String.self, forKey: .mountPath)
            allowedSpaceKeys = try c.decodeIfPresent([String].self, forKey: .allowedSpaceKeys)
            diskCache       = try c.decodeIfPresent(Bool.self, forKey: .diskCache) ?? true
            htmlView        = try c.decodeIfPresent(Bool.self, forKey: .htmlView) ?? false
            includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? false
            includeRestricted = try c.decodeIfPresent(Bool.self, forKey: .includeRestricted) ?? false
            autoMount       = try c.decodeIfPresent(Bool.self, forKey: .autoMount) ?? false
        }
    }

    public struct AuthEntry: Codable, Sendable, Equatable {
        public enum Method: String, Codable, Sendable { case apiToken = "api_token", pat }
        public var method: Method
        public var email: String?

        public init(method: Method, email: String? = nil) {
            self.method = method
            self.email = email
        }
    }

    public struct CacheTTLConfig: Codable, Sendable, Equatable {
        public var spaces: TimeInterval
        public var pages: TimeInterval
        public var pageDetail: TimeInterval
        public var attachments: TimeInterval
        public var attachmentBinary: TimeInterval
        /// Interval (seconds) for the background poll that auto-refreshes browsed
        /// page listings so newly created pages appear without re-enumeration.
        /// Negative disables polling entirely; `0` (default) means "derive from
        /// `pages`" for backward compatibility (and, when `pages` is `0` — i.e.
        /// caching disabled — polling is disabled too); a positive value sets the
        /// poll interval independently of the cache TTL. The volume enforces a
        /// lower bound to avoid hammering the API.
        public var refreshInterval: TimeInterval

        public init(spaces: TimeInterval, pages: TimeInterval, pageDetail: TimeInterval,
                    attachments: TimeInterval, attachmentBinary: TimeInterval,
                    refreshInterval: TimeInterval = 0) {
            self.spaces = spaces
            self.pages = pages
            self.pageDetail = pageDetail
            self.attachments = attachments
            self.attachmentBinary = attachmentBinary
            self.refreshInterval = refreshInterval
        }

        /// Resolves the effective periodic background-refresh interval (seconds),
        /// or `nil` when polling should be disabled. `refreshInterval` semantics:
        /// `< 0` → disabled; `> 0` → explicit; `0` → derive from the `pages` TTL
        /// (disabled when that TTL is `<= 0`, i.e. caching disabled). Non-finite
        /// (NaN/Inf) or negative inputs are treated as disabled, and the result is
        /// clamped to `[minimum, maximum]`, so an invalid hand-edited config can
        /// never produce a non-finite or out-of-range sleep duration.
        public func periodicRefreshInterval(minimum: TimeInterval, maximum: TimeInterval) -> TimeInterval? {
            guard refreshInterval.isFinite, refreshInterval >= 0 else { return nil }
            let derived = refreshInterval > 0 ? refreshInterval : pages
            guard derived.isFinite, derived > 0 else { return nil }
            return Swift.min(Swift.max(derived, minimum), maximum)
        }

        // Custom decoder so config files written before `refreshInterval` existed
        // (or hand-edited ones omitting it) decode with a 0 default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spaces           = try c.decode(TimeInterval.self, forKey: .spaces)
            pages            = try c.decode(TimeInterval.self, forKey: .pages)
            pageDetail       = try c.decode(TimeInterval.self, forKey: .pageDetail)
            attachments      = try c.decode(TimeInterval.self, forKey: .attachments)
            attachmentBinary = try c.decode(TimeInterval.self, forKey: .attachmentBinary)
            refreshInterval  = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 0
        }

        public static let `default` = CacheTTLConfig(
            spaces: 300,
            pages: 600,
            pageDetail: 600,
            attachments: 600,
            attachmentBinary: 1800
        )
    }

    public struct Pagination: Codable, Sendable, Equatable {
        public var limit: Int
        public init(limit: Int) { self.limit = limit }
        /// Confluence Cloud v2 caps page sizes around 250; DC commonly allows 200.
        public static let `default` = Pagination(limit: 100)
    }

    public static func load(from url: URL) throws -> ConfluenceConfiguration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ConfluenceConfiguration.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
