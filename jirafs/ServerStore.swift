import Foundation
import JiraAPI
import ConfluenceAPI
import JiraFSCore
import ConfluenceFSCore

/// The two Atlassian products a mount can expose.
enum MountProduct: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case jira
    case confluence
    var id: String { rawValue }

    var displayName: String { self == .jira ? "JIRA" : "Confluence" }
    /// URL scheme used by the matching FSKit extension.
    var scheme: String { self == .jira ? "jira" : "confluence" }
    /// FSKit module name passed to `mount -t`.
    var fsType: String { self == .jira ? "jirafs" : "confluencefs" }
    /// Default mount directory prefix.
    var defaultMountPrefix: String { self == .jira ? "~/jirafs" : "~/confluencefs" }
}

/// Shared authentication method for a server (applies to both products).
enum ServerAuthMethod: String, Codable, Sendable, Equatable {
    case apiToken = "api_token"
    case pat
    var displayName: String { self == .apiToken ? "API Token" : "PAT" }

    /// Keychain account name used for this method.
    /// API Token uses the email (or "api_token" when blank); PAT uses "pat".
    func keychainAccount(email: String?) -> String {
        switch self {
        case .apiToken:
            let e = email ?? ""
            return e.isEmpty ? "api_token" : e
        case .pat:
            return "pat"
        }
    }
}

/// A reusable Atlassian server: connection details for JIRA and/or Confluence
/// plus a single shared set of credentials. The credential token itself lives
/// in the Keychain, keyed by `id`.
struct Server: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    /// JIRA connection (optional — a server may expose only Confluence).
    var jira: JiraConnection?
    /// Confluence connection (optional — a server may expose only JIRA).
    var confluence: ConfluenceConnection?
    var auth: Auth

    struct JiraConnection: Codable, Sendable, Equatable {
        var url: URL
        var edition: JiraEdition
    }

    struct ConfluenceConnection: Codable, Sendable, Equatable {
        var url: URL
        var edition: ConfluenceEdition
    }

    struct Auth: Codable, Sendable, Equatable {
        var method: ServerAuthMethod
        var email: String?
    }

    init(id: String = UUID().uuidString, name: String,
         jira: JiraConnection? = nil, confluence: ConfluenceConnection? = nil,
         auth: Auth) {
        self.id = id
        self.name = name
        self.jira = jira
        self.confluence = confluence
        self.auth = auth
    }

    /// Whether this server can back a mount for the given product.
    func supports(_ product: MountProduct) -> Bool {
        switch product {
        case .jira: return jira != nil
        case .confluence: return confluence != nil
        }
    }

    /// Primary host for display (JIRA preferred, then Confluence).
    var displayHost: String? {
        jira?.url.host ?? confluence?.url.host
    }
}

/// A mount binds a server + product to a mount point with content filtering and
/// per-mount options. Several mounts may reference one server.
struct Mount: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var serverID: String
    var product: MountProduct
    var name: String
    /// Custom mount path; `nil` uses `<product default>/<name>`.
    var mountPath: String?
    /// Project keys (JIRA) or space keys (Confluence) to expose. `nil` = all.
    var allowedKeys: [String]?
    var diskCache: Bool
    var htmlView: Bool
    /// Confluence-only: include archived pages. Ignored for JIRA.
    var includeArchived: Bool
    /// Confluence-only: include pages with user/group restrictions. Ignored for JIRA.
    /// Defaults to `false` (restricted pages are excluded).
    var includeRestricted: Bool
    var autoMount: Bool

    init(id: String = UUID().uuidString, serverID: String, product: MountProduct,
         name: String, mountPath: String? = nil, allowedKeys: [String]? = nil,
         diskCache: Bool = true, htmlView: Bool = false,
         includeArchived: Bool = false, includeRestricted: Bool = false,
         autoMount: Bool = false) {
        self.id = id
        self.serverID = serverID
        self.product = product
        self.name = name
        self.mountPath = mountPath
        self.allowedKeys = allowedKeys
        self.diskCache = diskCache
        self.htmlView = htmlView
        self.includeArchived = includeArchived
        self.includeRestricted = includeRestricted
        self.autoMount = autoMount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(String.self, forKey: .id)
        serverID        = try c.decode(String.self, forKey: .serverID)
        product         = try c.decode(MountProduct.self, forKey: .product)
        name            = try c.decode(String.self, forKey: .name)
        mountPath       = try c.decodeIfPresent(String.self, forKey: .mountPath)
        allowedKeys     = try c.decodeIfPresent([String].self, forKey: .allowedKeys)
        diskCache       = try c.decodeIfPresent(Bool.self, forKey: .diskCache) ?? true
        htmlView        = try c.decodeIfPresent(Bool.self, forKey: .htmlView) ?? false
        includeArchived = try c.decodeIfPresent(Bool.self, forKey: .includeArchived) ?? false
        includeRestricted = try c.decodeIfPresent(Bool.self, forKey: .includeRestricted) ?? false
        autoMount       = try c.decodeIfPresent(Bool.self, forKey: .autoMount) ?? false
    }

    var effectiveMountPath: String {
        let raw = mountPath ?? "\(product.defaultMountPrefix)/\(name)"
        return (raw as NSString).expandingTildeInPath
    }
}

/// Host-app source of truth: the set of reusable servers and the mounts that
/// reference them, plus global cache/pagination defaults. Persisted as
/// `appstore.json` in the host app's Application Support directory. The host
/// derives the per-extension `config.json` files from this store.
struct AppStore: Codable, Sendable, Equatable {
    var version: Int
    var servers: [Server]
    var mounts: [Mount]
    var jiraCache: Configuration.CacheTTLConfig
    var confluenceCache: ConfluenceConfiguration.CacheTTLConfig
    var jiraPagination: Configuration.Pagination
    var confluencePagination: ConfluenceConfiguration.Pagination

    init(version: Int = 2,
         servers: [Server] = [],
         mounts: [Mount] = [],
         jiraCache: Configuration.CacheTTLConfig = .default,
         confluenceCache: ConfluenceConfiguration.CacheTTLConfig = .default,
         jiraPagination: Configuration.Pagination = .default,
         confluencePagination: ConfluenceConfiguration.Pagination = .default) {
        self.version = version
        self.servers = servers
        self.mounts = mounts
        self.jiraCache = jiraCache
        self.confluenceCache = confluenceCache
        self.jiraPagination = jiraPagination
        self.confluencePagination = confluencePagination
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
        jiraCache = try c.decodeIfPresent(Configuration.CacheTTLConfig.self, forKey: .jiraCache) ?? .default
        confluenceCache = try c.decodeIfPresent(ConfluenceConfiguration.CacheTTLConfig.self, forKey: .confluenceCache) ?? .default
        jiraPagination = try c.decodeIfPresent(Configuration.Pagination.self, forKey: .jiraPagination) ?? .default
        confluencePagination = try c.decodeIfPresent(ConfluenceConfiguration.Pagination.self, forKey: .confluencePagination) ?? .default
    }

    func server(id: String) -> Server? {
        servers.first { $0.id == id }
    }

    /// Mounts that reference the given server.
    func mounts(forServer serverID: String) -> [Mount] {
        mounts.filter { $0.serverID == serverID }
    }

    static func load(from url: URL) throws -> AppStore {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppStore.self, from: data)
    }

    func save(to url: URL) throws {
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
