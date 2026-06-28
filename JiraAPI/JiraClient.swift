import Foundation
import AtlassianCore

/// JIRA edition (Cloud uses REST API v3, Server uses v2).
public enum JiraEdition: String, Codable, Sendable {
    case cloud
    case server

    public var apiVersion: String {
        switch self {
        case .cloud: return "3"
        case .server: return "2"
        }
    }
}

/// Configuration for a single JIRA instance.
public struct JiraInstanceConfig: Sendable, Equatable {
    public let name: String
    public let baseURL: URL
    public let edition: JiraEdition

    public init(name: String, baseURL: URL, edition: JiraEdition) {
        self.name = name
        self.baseURL = baseURL
        self.edition = edition
    }
}

/// Common JIRA REST client interface used by the FSKit volume.
public protocol JiraClient: Sendable {
    var config: JiraInstanceConfig { get }

    func serverInfo() async throws
    func listProjects() async throws -> [JiraProject]
    func getProject(key: String) async throws -> JiraProject
    /// Searches for issues matching `jql`.
    ///
    /// - Parameter fields: JIRA field IDs to include in each issue's `fields`
    ///   object. Pass `[]` to request **no** fields (key is always returned as
    ///   a top-level property). Pass `nil` to request the standard full set.
    func searchIssues(jql: String, nextPageToken: String?, maxResults: Int, fields: [String]?) async throws -> JiraSearchResult
    func getIssue(key: String) async throws -> JiraIssue
    func listComments(issueKey: String) async throws -> [JiraComment]
    func listAttachments(issueKey: String) async throws -> [JiraAttachment]
    /// Downloads an attachment body, optionally a bounded byte window via an HTTP
    /// `Range` request. The returned ``RangedDownload`` reports whether the server
    /// honored the range (`206`) or returned the whole body (`200`).
    func downloadAttachment(_ attachment: JiraAttachment, range: Range<Int>?) async throws -> RangedDownload
    /// Returns all fields defined on the instance (id → name).
    func listFields() async throws -> [JiraField]
}

extension JiraClient {
    /// Backward-compatible overload that requests the full field set.
    public func searchIssues(jql: String, nextPageToken: String?, maxResults: Int) async throws -> JiraSearchResult {
        try await searchIssues(jql: jql, nextPageToken: nextPageToken, maxResults: maxResults, fields: nil)
    }
}
