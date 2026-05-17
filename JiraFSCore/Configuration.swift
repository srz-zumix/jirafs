import Foundation
import JiraAPI

/// On-disk configuration file (`.jirafs/config.json`) describing JIRA instances
/// and runtime knobs.
public struct Configuration: Codable, Sendable, Equatable {
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
        public var type: JiraEdition
        public var url: URL
        public var auth: AuthEntry
        /// Tilde-expanded path where this instance is mounted, e.g. `~/jirafs/myinstance`.
        /// `nil` uses the default `~/jirafs/<name>`.
        public var mountPath: String?
        /// Project keys to expose. `nil` means all projects; a non-empty array
        /// limits the file system to only those project keys (case-insensitive).
        public var allowedProjectKeys: [String]?
        /// When `true`, the cache manager persists entries to disk (AES-GCM encrypted)
        /// so they survive fskitd restarts. Defaults to `false`.
        public var diskCache: Bool

        public var id: String { name }

        public var effectiveMountPath: String {
            let raw = mountPath ?? "~/jirafs/\(name)"
            return (raw as NSString).expandingTildeInPath
        }

        public init(name: String, type: JiraEdition, url: URL, auth: AuthEntry,
                    mountPath: String? = nil, allowedProjectKeys: [String]? = nil,
                    diskCache: Bool = false) {
            self.name = name
            self.type = type
            self.url = url
            self.auth = auth
            self.mountPath = mountPath
            self.allowedProjectKeys = allowedProjectKeys
            self.diskCache = diskCache
        }

        // Custom decoder: `diskCache` key was added later → default false.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name             = try c.decode(String.self, forKey: .name)
            type             = try c.decode(JiraEdition.self, forKey: .type)
            url              = try c.decode(URL.self, forKey: .url)
            auth             = try c.decode(AuthEntry.self, forKey: .auth)
            mountPath        = try c.decodeIfPresent(String.self, forKey: .mountPath)
            allowedProjectKeys = try c.decodeIfPresent([String].self, forKey: .allowedProjectKeys)
            diskCache        = try c.decodeIfPresent(Bool.self, forKey: .diskCache) ?? false
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
        public var projects: TimeInterval
        public var issues: TimeInterval
        public var issueDetail: TimeInterval
        public var attachments: TimeInterval
        public var attachmentBinary: TimeInterval

        public static let `default` = CacheTTLConfig(
            projects: 300,
            issues: 600,
            issueDetail: 600,
            attachments: 600,
            attachmentBinary: 1800
        )
    }

    public struct Pagination: Codable, Sendable, Equatable {
        public var maxResults: Int
        /// JIRA Server JQL allows up to 1000 results per request; Cloud caps at 100.
        public static let `default` = Pagination(maxResults: 1000)
    }

    public static func load(from url: URL) throws -> Configuration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Configuration.self, from: data)
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
