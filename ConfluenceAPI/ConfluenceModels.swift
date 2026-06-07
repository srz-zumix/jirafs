import Foundation

// Domain models for Confluence content. These are edition-agnostic; the REST
// client maps the Cloud (v2) and Data Center (v1) wire formats onto them.

// MARK: - Space

public struct ConfluenceSpace: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let key: String
    public let name: String
    public let type: String?
    /// The id of the space home page, when known.
    public let homepageId: String?

    public init(id: String, key: String, name: String, type: String? = nil, homepageId: String? = nil) {
        self.id = id
        self.key = key
        self.name = name
        self.type = type
        self.homepageId = homepageId
    }
}

// MARK: - Body

/// A rendered body in a particular representation.
public struct ConfluenceBody: Codable, Sendable, Equatable {
    public let format: ConfluenceBodyFormat
    /// Raw body value: XHTML for `.storage`, JSON text for `.atlasDocFormat`.
    public let value: String

    public init(format: ConfluenceBodyFormat, value: String) {
        self.format = format
        self.value = value
    }
}

// MARK: - Page

public struct ConfluencePage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let spaceId: String?
    public let parentId: String?
    public let body: ConfluenceBody?
    public let version: Int?
    public let authorId: String?
    public let createdAt: String?
    /// Absolute or relative URL to view the page in a browser, when known.
    public let webURL: String?
    /// `true` if the page has any user/group restrictions (read or update operation).
    /// `nil` means restriction status is unknown (e.g., loaded from older cache or
    /// Cloud list where restriction data is fetched separately).
    public let hasRestrictions: Bool?

    public init(
        id: String,
        title: String,
        spaceId: String? = nil,
        parentId: String? = nil,
        body: ConfluenceBody? = nil,
        version: Int? = nil,
        authorId: String? = nil,
        createdAt: String? = nil,
        webURL: String? = nil,
        hasRestrictions: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.spaceId = spaceId
        self.parentId = parentId
        self.body = body
        self.version = version
        self.authorId = authorId
        self.createdAt = createdAt
        self.webURL = webURL
        self.hasRestrictions = hasRestrictions
    }
}

// MARK: - Comment

public struct ConfluenceComment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let body: ConfluenceBody?
    /// Human-readable author name. Available on Data Center; nil on Cloud,
    /// where only an opaque account id is returned (see `authorId`).
    public let authorDisplayName: String?
    /// Opaque author account id, when a display name is not available.
    public let authorId: String?
    public let createdAt: String?

    public init(
        id: String,
        body: ConfluenceBody? = nil,
        authorDisplayName: String? = nil,
        authorId: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.body = body
        self.authorDisplayName = authorDisplayName
        self.authorId = authorId
        self.createdAt = createdAt
    }

    /// Best label for the author: display name when known, else the account id.
    public var authorLabel: String? {
        authorDisplayName ?? authorId
    }
}

// MARK: - Attachment

public struct ConfluenceAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let mediaType: String?
    public let fileSize: Int?
    /// Download path or absolute URL. Resolved against the instance base URL
    /// when relative.
    public let downloadLink: String?

    public init(
        id: String,
        title: String,
        mediaType: String? = nil,
        fileSize: Int? = nil,
        downloadLink: String? = nil
    ) {
        self.id = id
        self.title = title
        self.mediaType = mediaType
        self.fileSize = fileSize
        self.downloadLink = downloadLink
    }
}

// MARK: - Label

public struct ConfluenceLabel: Codable, Sendable, Equatable, Identifiable {
    public let id: String?
    public let name: String
    public let prefix: String?

    public init(id: String? = nil, name: String, prefix: String? = nil) {
        self.id = id
        self.name = name
        self.prefix = prefix
    }
}
