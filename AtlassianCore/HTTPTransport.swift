import Foundation

/// HTTP transport used by Atlassian REST clients. Abstracted so tests can stub
/// `URLSession` without `URLProtocol` plumbing.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Streams the response body to a temporary file on disk and returns its URL
    /// plus the response. The caller takes ownership of the returned file and is
    /// responsible for deleting it. Used for attachment bodies so a multi-GB file
    /// is never buffered fully in memory.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

public extension HTTPTransport {
    /// Default implementation that buffers the body via `data(for:)` and writes
    /// it to a temporary file. Conforming stubs that only implement `data(for:)`
    /// (e.g. test transports) get file downloads for free; production transports
    /// override this with a truly streaming implementation.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (data, http) = try await data(for: request)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .atomic)
        return (url, http)
    }
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

    /// Streams the response straight to disk via `URLSession.download`, so the
    /// body is never held in memory. `URLSession` stores the result in a
    /// system-managed temporary file that it deletes as soon as this call
    /// returns, so the file is moved to a caller-owned location immediately.
    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (tempURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw AtlassianError.transport("non-HTTP response")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return (dest, http)
    }
}
