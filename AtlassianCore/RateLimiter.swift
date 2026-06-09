import Foundation

/// Wraps an async operation with retry-on-429 and exponential backoff for
/// transient server errors.
public actor RateLimiter {
    public let maxRetries: Int
    public let baseDelay: TimeInterval

    public init(maxRetries: Int = 3, baseDelay: TimeInterval = 0.5) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxRetryAfter = 60
    }

    /// Maximum seconds to honour from a server-supplied `Retry-After` value.
    /// Caps an arbitrarily large value to prevent a denial-of-service where a
    /// misbehaving (or malicious) server stalls the app indefinitely.
    public let maxRetryAfter: TimeInterval

    public init(maxRetries: Int = 3, baseDelay: TimeInterval = 0.5,
                maxRetryAfter: TimeInterval = 60) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxRetryAfter = maxRetryAfter
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as AtlassianError {
                attempt += 1
                guard attempt <= maxRetries else { throw error }
                switch error {
                case .rateLimited(let retryAfter):
                    let raw = retryAfter ?? backoff(attempt)
                    let delay = min(raw, maxRetryAfter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                case .serverError(let status) where (500..<600).contains(status):
                    try await Task.sleep(nanoseconds: UInt64(backoff(attempt) * 1_000_000_000))
                default:
                    throw error
                }
            }
        }
    }

    private func backoff(_ attempt: Int) -> TimeInterval {
        baseDelay * pow(2.0, Double(attempt - 1))
    }
}
