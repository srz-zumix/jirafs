import Foundation

/// Sendable type-erased JSON value used for fields whose shape depends on the
/// Atlassian edition (ADF on Cloud, wiki markup / storage format on Server).
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Maximum nesting depth accepted while decoding. A malicious or buggy
    /// instance could otherwise return deeply nested JSON (e.g. in an ADF body)
    /// and exhaust the stack during recursive decoding. `Decoder.codingPath`
    /// grows by one element per nesting level, so checking it bounds the
    /// recursion before it can crash.
    private static let maxDepth = 100

    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= Self.maxDepth else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "JSON nesting deeper than \(Self.maxDepth) levels"
                )
            )
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
