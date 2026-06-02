import Foundation
@_exported import AtlassianCore

// MARK: - Backward-compatibility aliases
//
// The generic networking / auth / caching primitives moved to `AtlassianCore`
// so they can be shared with the Confluence client. These typealiases keep the
// existing JIRA-flavoured names compiling unchanged.

/// Errors thrown by the JIRA API client. See `AtlassianError`.
public typealias JiraAPIError = AtlassianError

/// HTTP transport protocol used by `JiraRESTClient`. See `HTTPTransport`.
public typealias JiraHTTPTransport = HTTPTransport
