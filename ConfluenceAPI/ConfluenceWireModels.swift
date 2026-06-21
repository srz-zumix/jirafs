import Foundation

// Internal wire-format DTOs. These decode the Cloud (v2) and Data Center (v1)
// JSON shapes and project them onto the shared `Confluence*` domain models.

// MARK: - Cloud (REST v2)

/// Cloud paginated envelope: `{ "results": [...], "_links": { "next": "..." } }`.
struct CloudList<Element: Decodable>: Decodable {
    let results: [Element]
    private let links: Links?

    enum CodingKeys: String, CodingKey {
        case results
        case links = "_links"
    }

    struct Links: Decodable { let next: String? }

    /// Extracts the opaque `cursor` query item from the `next` link, if present.
    var cursor: String? {
        guard let next = links?.next,
              let comps = URLComponents(string: next) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "cursor" })?.value
    }
}

struct CloudSpace: Decodable {
    let id: String
    let key: String
    let name: String
    let type: String?
    let homepageId: String?

    var domain: ConfluenceSpace {
        ConfluenceSpace(id: id, key: key, name: name, type: type, homepageId: homepageId)
    }
}

struct CloudBodyValue: Decodable {
    let value: String?
    let representation: String?
}

struct CloudBody: Decodable {
    let storage: CloudBodyValue?
    let atlasDocFormat: CloudBodyValue?

    enum CodingKeys: String, CodingKey {
        case storage
        case atlasDocFormat = "atlas_doc_format"
    }

    func body(preferred: ConfluenceBodyFormat?) -> ConfluenceBody? {
        switch preferred {
        case .atlasDocFormat:
            if let v = atlasDocFormat?.value { return ConfluenceBody(format: .atlasDocFormat, value: v) }
        case .storage, nil:
            if let v = storage?.value { return ConfluenceBody(format: .storage, value: v) }
        }
        if let v = storage?.value { return ConfluenceBody(format: .storage, value: v) }
        if let v = atlasDocFormat?.value { return ConfluenceBody(format: .atlasDocFormat, value: v) }
        return nil
    }
}

struct CloudPage: Decodable {
    let id: String
    let title: String
    let spaceId: String?
    let parentId: String?
    let authorId: String?
    let createdAt: String?
    let version: CloudVersion?
    let body: CloudBody?
    private let links: CloudLinks?

    enum CodingKeys: String, CodingKey {
        case id, title, spaceId, parentId, authorId, createdAt, version, body
        case links = "_links"
    }

    struct CloudVersion: Decodable { let number: Int? }
    struct CloudLinks: Decodable { let webui: String? }

    func domain(format: ConfluenceBodyFormat?) -> ConfluencePage {
        ConfluencePage(
            id: id,
            title: title,
            spaceId: spaceId,
            parentId: parentId,
            body: body?.body(preferred: format),
            version: version?.number,
            authorId: authorId,
            createdAt: createdAt,
            webURL: links?.webui
        )
    }
}

struct CloudComment: Decodable {
    let id: String
    let body: CloudBody?
    let version: Version?

    struct Version: Decodable { let authorId: String?; let createdAt: String? }

    var domain: ConfluenceComment {
        ConfluenceComment(
            id: id,
            body: body?.body(preferred: .storage),
            authorDisplayName: nil,
            authorId: version?.authorId,
            createdAt: version?.createdAt
        )
    }
}

struct CloudAttachment: Decodable {
    let id: String
    let title: String
    let mediaType: String?
    let fileSize: Int?
    let downloadLink: String?

    var domain: ConfluenceAttachment {
        ConfluenceAttachment(id: id, title: title, mediaType: mediaType, fileSize: fileSize, downloadLink: downloadLink)
    }
}

struct CloudLabel: Decodable {
    let id: String?
    let name: String
    let prefix: String?

    var domain: ConfluenceLabel {
        ConfluenceLabel(id: id, name: name, prefix: prefix)
    }
}

// MARK: - Data Center (REST v1)

/// DC paginated envelope: `{ "results": [...], "start": 0, "limit": 25, "size": 25, "_links": { "next": "..." } }`.
struct DCList<Element: Decodable>: Decodable {
    let results: [Element]
    let start: Int?
    let limit: Int?
    let size: Int?
    let links: Links?

    enum CodingKeys: String, CodingKey {
        case results, start, limit, size
        case links = "_links"
    }

    struct Links: Decodable { let next: String? }
}

struct DCSpace: Decodable {
    let id: Int?
    let key: String
    let name: String
    let type: String?
    let homepage: Ref?

    struct Ref: Decodable { let id: String? }

    var domain: ConfluenceSpace {
        // DC space pages are addressed by key; keep id aligned with key when the
        // numeric id is absent so downstream code can use either uniformly.
        ConfluenceSpace(
            id: id.map(String.init) ?? key,
            key: key,
            name: name,
            type: type,
            homepageId: homepage?.id
        )
    }
}

struct DCBody: Decodable {
    let storage: Value?
    struct Value: Decodable { let value: String?; let representation: String? }

    var confluenceBody: ConfluenceBody? {
        guard let v = storage?.value else { return nil }
        return ConfluenceBody(format: .storage, value: v)
    }
}

// MARK: - Restrictions (shared by DC list expand and Cloud v1 list)

/// Restriction subjects for one operation (read / update).
/// Only `size` is decoded; the full user/group objects are ignored.
struct PageRestrictionSubjects: Decodable {
    struct SizeOnly: Decodable { let size: Int? }
    let user: SizeOnly?
    let group: SizeOnly?

    var hasAny: Bool {
        (user?.size ?? 0) > 0 || (group?.size ?? 0) > 0
    }
}

struct PageRestrictionOperation: Decodable {
    let restrictions: PageRestrictionSubjects?
}

/// Page-level restrictions object: `{ "read": {...}, "update": {...} }`.
struct PageRestrictions: Decodable {
    let read: PageRestrictionOperation?
    let update: PageRestrictionOperation?

    /// `true` if any user/group restriction exists for any operation.
    var hasAny: Bool {
        (read?.restrictions?.hasAny ?? false) || (update?.restrictions?.hasAny ?? false)
    }
}

struct DCUser: Decodable { let displayName: String? }

struct DCVersion: Decodable {
    let number: Int?
    let by: DCUser?
    let when: String?
}

struct DCHistory: Decodable {
    let createdBy: DCUser?
    let createdDate: String?
}

struct DCPage: Decodable {
    let id: String
    let title: String
    let space: Space?
    let ancestors: [Ancestor]?
    let version: DCVersion?
    let history: DCHistory?
    let body: DCBody?
    let restrictions: PageRestrictions?
    let links: Links?

    enum CodingKeys: String, CodingKey {
        case id, title, space, ancestors, version, history, body, restrictions
        case links = "_links"
    }

    struct Space: Decodable { let id: Int?; let key: String? }
    struct Ancestor: Decodable { let id: String? }
    struct Links: Decodable { let webui: String? }

    var domain: ConfluencePage {
        ConfluencePage(
            id: id,
            title: title,
            spaceId: space?.id.map(String.init) ?? space?.key,
            parentId: ancestors?.last?.id,
            body: body?.confluenceBody,
            version: version?.number,
            authorId: version?.by?.displayName ?? history?.createdBy?.displayName,
            createdAt: history?.createdDate ?? version?.when,
            webURL: links?.webui,
            hasRestrictions: restrictions.map(\.hasAny)
        )
    }
}

// MARK: - Cloud v1 Content list (for restricted page ID collection)

/// Wire model for the Cloud v1 page-list endpoints used to collect restricted
/// page IDs: `GET /wiki/rest/api/space/{spaceKey}/content/page` (root pages) and
/// `GET /wiki/rest/api/content/{id}/child/page` (child pages), both expanded
/// with the read/update restriction users and groups.
/// Only the fields needed for restriction detection are decoded.
struct V1ContentList: Decodable {
    let results: [V1ContentItem]
    let start: Int?
    let size: Int?
    let links: Links?

    enum CodingKeys: String, CodingKey {
        case results, start, size
        case links = "_links"
    }
    struct Links: Decodable { let next: String? }
}

struct V1ContentItem: Decodable {
    let id: String
    let restrictions: PageRestrictions?
}

struct DCComment: Decodable {
    let id: String
    let body: DCBody?
    let version: DCVersion?
    let history: DCHistory?

    var domain: ConfluenceComment {
        ConfluenceComment(
            id: id,
            body: body?.confluenceBody,
            authorDisplayName: history?.createdBy?.displayName ?? version?.by?.displayName,
            authorId: nil,
            createdAt: history?.createdDate ?? version?.when
        )
    }
}

struct DCAttachment: Decodable {
    let id: String
    let title: String
    let metadata: Metadata?
    let extensions: Extensions?
    let links: Links?

    enum CodingKeys: String, CodingKey {
        case id, title, metadata, extensions
        case links = "_links"
    }

    struct Metadata: Decodable { let mediaType: String? }
    struct Extensions: Decodable { let mediaType: String?; let fileSize: Int? }
    struct Links: Decodable { let download: String? }

    var domain: ConfluenceAttachment {
        ConfluenceAttachment(
            id: id,
            title: title,
            mediaType: extensions?.mediaType ?? metadata?.mediaType,
            fileSize: extensions?.fileSize,
            downloadLink: links?.download
        )
    }
}

struct DCLabel: Decodable {
    let id: String?
    let name: String
    let prefix: String?

    var domain: ConfluenceLabel {
        ConfluenceLabel(id: id, name: name, prefix: prefix)
    }
}

// MARK: - Cloud Folder children (REST v2)

/// Wire model for items returned by the v2 `direct-children` endpoints
/// (`GET /wiki/api/v2/pages/{id}/direct-children` and
/// `GET /wiki/api/v2/folders/{id}/direct-children`). Each item is tagged with a
/// `type` (`page`, `folder`, `whiteboard`, `database`, `embed`); only `page` and
/// `folder` are surfaced by the file system. The `direct-children` response omits
/// `parentId`/`authorId`/`createdAt`/`version`/`_links`, so those fields stay nil.
struct CloudFolderChild: Decodable {
    let id: String
    let title: String
    let type: String            // "page", "folder", "whiteboard", "database", "embed"
    let spaceId: String?
    let parentId: String?
    let authorId: String?       // page-only
    let createdAt: String?      // page-only
    let version: CloudVersion?  // page-only
    private let links: CloudLinks?

    struct CloudVersion: Decodable { let number: Int? }
    struct CloudLinks: Decodable { let webui: String? }

    enum CodingKeys: String, CodingKey {
        case id, title, type, spaceId, parentId, authorId, createdAt, version
        case links = "_links"
    }

    var domain: ConfluenceFolderChild {
        let ct: ConfluenceFolderChild.ContentType
        switch type {
        case "page": ct = .page
        case "folder": ct = .folder
        default: ct = .other
        }
        return ConfluenceFolderChild(
            contentType: ct, id: id, title: title,
            spaceId: spaceId, parentId: parentId,
            version: version?.number, authorId: authorId,
            createdAt: createdAt, webURL: links?.webui
        )
    }
}
