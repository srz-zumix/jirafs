import Foundation

/// HTTP transport used by `JiraRESTClient`. Abstracted so tests can stub
/// `URLSession` without `URLProtocol` plumbing.
public protocol JiraHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: JiraHTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JiraAPIError.transport("non-HTTP response")
        }
        return (data, http)
    }
}
