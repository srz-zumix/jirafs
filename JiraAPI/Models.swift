import Foundation

// MARK: - Project

public struct JiraProject: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let key: String
    public let name: String
    public let projectTypeKey: String?
    public let lead: JiraUser?

    public init(
        id: String,
        key: String,
        name: String,
        projectTypeKey: String? = nil,
        lead: JiraUser? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.projectTypeKey = projectTypeKey
        self.lead = lead
    }
}

// MARK: - User

public struct JiraUser: Codable, Sendable, Equatable {
    public let accountId: String?
    public let displayName: String?
    public let emailAddress: String?

    public init(accountId: String? = nil, displayName: String? = nil, emailAddress: String? = nil) {
        self.accountId = accountId
        self.displayName = displayName
        self.emailAddress = emailAddress
    }
}

// MARK: - Issue

public struct JiraIssue: Codable, Sendable, Equatable {
    public let id: String
    public let key: String
    public let fields: JiraIssueFields

    public init(id: String, key: String, fields: JiraIssueFields) {
        self.id = id
        self.key = key
        self.fields = fields
    }
}

public struct JiraIssueFields: Codable, Sendable, Equatable {
    public var summary: String?
    public var description: JSONValue?
    public var issueType: NamedValue?
    public var status: NamedValue?
    public var priority: NamedValue?
    public var assignee: JiraUser?
    public var reporter: JiraUser?
    public var labels: [String]?
    public var components: [NamedValue]?
    public var created: String?
    public var updated: String?
    public var resolution: NamedValue?
    public var parent: JiraIssueRef?
    public var subtasks: [JiraIssueRef]?
    public var issuelinks: [JiraIssueLink]?

    public enum CodingKeys: String, CodingKey {
        case summary, description, status, priority, assignee, reporter
        case labels, components, created, updated, resolution
        case parent, subtasks, issuelinks
        case issueType = "issuetype"
    }

    public init() {}

    public struct NamedValue: Codable, Sendable, Equatable {
        public let name: String?
        public init(name: String?) { self.name = name }
    }
}

public struct JiraIssueRef: Codable, Sendable, Equatable {
    public let id: String?
    public let key: String?
    public init(id: String?, key: String?) { self.id = id; self.key = key }
}

public struct JiraIssueLink: Codable, Sendable, Equatable {
    public let id: String?
    public let type: LinkType
    public let outwardIssue: JiraIssueRef?
    public let inwardIssue: JiraIssueRef?

    public struct LinkType: Codable, Sendable, Equatable {
        public let name: String?
        public let inward: String?
        public let outward: String?
    }
}

// MARK: - Comment

public struct JiraComment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let author: JiraUser?
    public let body: JSONValue?
    public let created: String?
    public let updated: String?

    public init(
        id: String,
        author: JiraUser? = nil,
        body: JSONValue? = nil,
        created: String? = nil,
        updated: String? = nil
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.created = created
        self.updated = updated
    }
}

public struct JiraCommentList: Codable, Sendable, Equatable {
    public let comments: [JiraComment]
    public let startAt: Int?
    public let maxResults: Int?
    public let total: Int?
}

// MARK: - Attachment

public struct JiraAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let filename: String
    public let size: Int
    public let mimeType: String?
    public let content: String?
    public let created: String?
    public let author: JiraUser?
}

// MARK: - Search

public struct JiraSearchResult: Codable, Sendable, Equatable {
    public let startAt: Int
    public let maxResults: Int
    public let total: Int
    public let issues: [JiraIssue]
}

// MARK: - Generic JSON

/// Sendable type-erased JSON value used for fields whose shape depends on the
/// JIRA edition (ADF on Cloud, wiki markup string on Server).
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
