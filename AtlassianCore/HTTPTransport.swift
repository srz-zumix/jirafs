import Foundation

/// HTTP transport used by Atlassian REST clients. Abstracted so tests can stub
/// `URLSession` without `URLProtocol` plumbing.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = URLSessionTransport.defaultSession) {
        self.session = session
    }

    /// Shared session with explicit timeouts. `URLSession.shared` defaults to a
    /// 60s request timeout and a 7-day resource timeout; because FSKit file
    /// operations block on these requests, a hung connection would otherwise
    /// stall the mounted volume. The request timeout bounds an individual call,
    /// and the resource timeout caps each bounded-Range attachment chunk.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AtlassianError.transport("non-HTTP response")
        }
        return (data, http)
    }
}
