import Foundation

/// HTTP transport used by Atlassian REST clients. Abstracted so tests can stub
/// `URLSession` without `URLProtocol` plumbing.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AtlassianError.transport("non-HTTP response")
        }
        return (data, http)
    }
}
