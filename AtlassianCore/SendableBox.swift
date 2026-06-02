import Foundation

/// Wraps a non-Sendable value so it can cross actor boundaries. The caller
/// must guarantee the wrapped value is only accessed safely.
public struct SendableBox<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}
