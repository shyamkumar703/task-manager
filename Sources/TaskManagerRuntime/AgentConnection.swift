import CodexTransport
import Foundation
import TaskManagerCore

public protocol AgentConnection: Sendable {
    var events: AsyncStream<CodexClient.Event> { get }
    func connect() async throws
    func request(_ method: String, params: JSONValue) async throws -> JSONValue
    func stop() async
}

public struct CodexConnection: AgentConnection {
    private let client = CodexClient()
    public var events: AsyncStream<CodexClient.Event> { client.events }
    public init() {}
    public func connect() async throws {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ String($0) + "/codex" }).first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ManagerError.notFound("codex was not found on PATH")
        }
        try await client.start(executable: URL(fileURLWithPath: path))
        _ = try await client.initialize()
    }
    public func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        try await client.request(method, params: params, timeout: .seconds(30))
    }
    public func stop() async { await client.stop() }
}

struct AgentResult: Codable {
    let status: String
    let text: String
    static let schema: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "properties": .object([
            "status": .object(["type": .string("string"), "enum": .array([.string("completed"), .string("question")])]),
            "text": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("status"), .string("text")]),
    ])
}
