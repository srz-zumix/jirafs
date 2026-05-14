import Foundation

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
    func searchIssues(jql: String, nextPageToken: String?, maxResults: Int) async throws -> JiraSearchResult
    func getIssue(key: String) async throws -> JiraIssue
    func listComments(issueKey: String) async throws -> [JiraComment]
    func listAttachments(issueKey: String) async throws -> [JiraAttachment]
    func downloadAttachment(_ attachment: JiraAttachment, range: Range<Int>?) async throws -> Data
}
