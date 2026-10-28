import Foundation

/// Loss-free JSON value. The *arr APIs and Jellyfin expect whole resources back on update
/// (PUT /series/{id}, POST /Users/{id}/Policy), so edits are made on the raw document to keep every
/// field the app does not model.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Keep integers integral so ids round-trip exactly ("id": 12, not 12.0).
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        get { if case .object(let dict) = self { return dict[key] } else { return nil } }
        set {
            guard case .object(var dict) = self else { return }
            dict[key] = newValue
            self = .object(dict)
        }
    }

    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var intValue: Int? { if case .number(let v) = self { Int(v) } else { nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }

    public init(_ value: Int) { self = .number(Double(value)) }

    /// Decodes a typed view of this value.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try ServiceClient.decode(T.self, from: try JSONEncoder.service.encode(self))
    }
}
