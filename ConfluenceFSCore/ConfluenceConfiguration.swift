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

    public struct InstanceEntry: Codable, Sendable, Equatable, Identifiable {
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
        /// When `true`, this instance is automatically mounted when the app launches.
        /// Defaults to `false`.
        public var autoMount: Bool

        public var id: String { name }

        public var effectiveMountPath: String {
            let raw = mountPath ?? "~/confluencefs/\(name)"
            return (raw as NSString).expandingTildeInPath
        }

        public init(name: String, type: ConfluenceEdition, url: URL, auth: AuthEntry,
                    mountPath: String? = nil, allowedSpaceKeys: [String]? = nil,
                    diskCache: Bool = true, htmlView: Bool = false, includeArchived: Bool = false,
                    autoMount: Bool = false) {
            self.name = name
            self.type = type
            self.url = url
            self.auth = auth
            self.mountPath = mountPath
            self.allowedSpaceKeys = allowedSpaceKeys
            self.diskCache = diskCache
            self.htmlView = htmlView
            self.includeArchived = includeArchived
            self.autoMount = autoMount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name            = try c.decode(String.self, forKey: .name)
            type            = try c.decode(ConfluenceEdition.self, forKey: .type)
            url             = try c.decode(URL.self, forKey: .url)
            auth            = try c.decode(AuthEntry.self, forKey: .auth)
            mountPath       = try c.decodeIfPresent(String.self, forKey: .mountPath)
            allowedSpaceKeys = try c.decodeIfPresent([String].self, forKey: .allowedSpaceKeys)
            diskCache       = try c.decodeIfPresent(Bool.self, forKey: .diskCache) ?? true
            htmlView        = try c.decodeIfPresent(Bool.self, forKey: .htmlView) ?? false
            includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? false
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

        public init(spaces: TimeInterval, pages: TimeInterval, pageDetail: TimeInterval,
                    attachments: TimeInterval, attachmentBinary: TimeInterval) {
            self.spaces = spaces
            self.pages = pages
            self.pageDetail = pageDetail
            self.attachments = attachments
            self.attachmentBinary = attachmentBinary
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
