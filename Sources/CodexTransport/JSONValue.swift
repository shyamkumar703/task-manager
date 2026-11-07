import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), double(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integer: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }
}

public enum TransportError: Error, Sendable, CustomStringConvertible {
    case disconnected, timeout, invalidMessage, oversizedMessage, backlogExceeded, alreadyStarted
    case remote(code: Int64, message: String)

    public var description: String {
        switch self {
        case .disconnected: "Codex transport disconnected"
        case .timeout: "Codex request timed out"
        case .invalidMessage: "Invalid Codex JSON-RPC message"
        case .oversizedMessage: "Codex message exceeds the size limit"
        case .backlogExceeded: "Codex output exceeded the bounded event queue"
        case .alreadyStarted: "Codex transport has already been started"
        case .remote(let code, let message): "Codex error \(code): \(message)"
        }
    }
}
