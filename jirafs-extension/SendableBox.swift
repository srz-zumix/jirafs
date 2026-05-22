import Foundation

/// Wraps a non-Sendable value so it can cross actor boundaries. The caller
/// must guarantee the wrapped value is only accessed safely.
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
