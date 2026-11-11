import CodexTransport
import Foundation
import TaskManagerCore

public protocol AgentConnection: Sendable {
    var events: AsyncStream<CodexClient.Event> { get }
    var remoteAddress: String? { get }
    func connect() async throws
    func request(_ method: String, params: JSONValue) async throws -> JSONValue
    func stop() async
}

public extension AgentConnection {
    var remoteAddress: String? { nil }
}

public struct CodexConnection: AgentConnection {
    private let sharedServer: SharedCodexServer?
    public var remoteAddress: String? { sharedServer?.address }
    private let client = CodexClient()
    public var events: AsyncStream<CodexClient.Event> { client.events }
    public init(shared: Bool = false) { sharedServer = shared ? SharedCodexServer() : nil }
    public func connect() async throws {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let path = paths.map({ String($0) + "/codex" }).first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ManagerError.notFound("codex was not found on PATH")
        }
        let executable = URL(fileURLWithPath: path)
        do {
            if let sharedServer {
                try await sharedServer.start(executable: executable)
                try await client.connect(unixSocket: String(sharedServer.address.dropFirst("unix://".count)))
            } else { try await client.start(executable: executable) }
            _ = try await client.initialize()
        } catch { await stop(); throw error }
    }
    public func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        try await client.request(method, params: params, timeout: .seconds(30))
    }
    public func stop() async { await client.stop(); await sharedServer?.stop() }
}

struct AgentResult: Codable {
    let status: String
    let text: String
    let reply: String?
    let sourceReplies: [SourceReply]?
    init(status: String, text: String, reply: String? = nil, sourceReplies: [SourceReply]? = nil) { self.status = status; self.text = text; self.reply = reply; self.sourceReplies = sourceReplies }
    static let schema: JSONValue = .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "properties": .object([
            "status": .object(["type": .string("string"), "enum": .array([.string("completed"), .string("question")])]),
            "text": .object(["type": .string("string")]),
            "reply": .object(["type": .array([.string("string"), .string("null")])]),
            "sourceReplies": .object(["type": .string("array"), "items": .object([
                "type": .string("object"), "additionalProperties": .bool(false),
                "properties": .object(["sourceEventID": .object(["type": .string("integer")]), "text": .object(["type": .string("string")])]),
                "required": .array([.string("sourceEventID"), .string("text")]),
            ])]),
        ]),
        "required": .array([.string("status"), .string("text"), .string("reply"), .string("sourceReplies")]),
    ])
}
