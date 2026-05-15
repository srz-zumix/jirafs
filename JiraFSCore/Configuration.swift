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

        public var id: String { name }

        public var effectiveMountPath: String {
            let raw = mountPath ?? "~/jirafs/\(name)"
            return (raw as NSString).expandingTildeInPath
        }

        public init(name: String, type: JiraEdition, url: URL, auth: AuthEntry, mountPath: String? = nil) {
            self.name = name
            self.type = type
            self.url = url
            self.auth = auth
            self.mountPath = mountPath
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
            issues: 60,
            issueDetail: 30,
            attachments: 600,
            attachmentBinary: 1800
        )
    }

    public struct Pagination: Codable, Sendable, Equatable {
        public var maxResults: Int
        public static let `default` = Pagination(maxResults: 100)
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
