import CodexTransport
import Foundation
import TaskManagerCore
import TaskManagerPersistence

/// Persists telemetry before forwarding completion, including failed/interrupted turns.
/// Shared by workers and short-lived coordinator model calls.
public actor UsageTrackingConnection: AgentConnection {
    public nonisolated let events: AsyncStream<CodexClient.Event>
    public nonisolated var remoteAddress: String? { base.remoteAddress }
    private let continuation: AsyncStream<CodexClient.Event>.Continuation
    private let base: any AgentConnection
    private let store: Store
    private let taskID: String?
    private let sourceEventID: Int64?
    private let role: String
    private var relay: Task<Void, Never>?

    public init(base: any AgentConnection, store: Store, role: String, taskID: String? = nil, sourceEventID: Int64? = nil) {
        self.base = base; self.store = store; self.role = role; self.taskID = taskID; self.sourceEventID = sourceEventID
        let pair = AsyncStream<CodexClient.Event>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = pair.stream; continuation = pair.continuation
    }
    public func connect() async throws {
        try await base.connect()
        relay = Task { [weak self, base, events = base.events, continuation] in
            for await event in events {
                guard let self else { break }
                await self.observe(event)
                if case .dropped = continuation.yield(event) {
                    await base.stop()
                    break
                }
            }
            continuation.finish()
        }
    }
    public func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        let response = try await base.request(method, params: params)
        if ["thread/start", "thread/resume"].contains(method), let id = response["thread"]?["id"]?.string {
            do {
                try await store.registerUsageThread(threadID: id, taskID: taskID, sourceEventID: sourceEventID, role: role,
                    model: response["model"]?.string ?? response["thread"]?["model"]?.string,
                    provider: response["modelProvider"]?.string ?? response["thread"]?["modelProvider"]?.string,
                    effort: response["reasoningEffort"]?.string, serviceTier: response["serviceTier"]?.string, resumed: method == "thread/resume")
            } catch {
                try? await store.record(taskID: taskID, kind: "usage.tracking.failed", detail: String(describing: error))
            }
        }
        return response
    }
    public func stop() async {
        await base.stop()
        await relay?.value
        relay = nil
        continuation.finish()
    }
    private func observe(_ event: CodexClient.Event) async {
        do {
            if event.method == "model/rerouted", let thread = event.params["threadId"]?.string, let model = event.params["toModel"]?.string {
                try await store.updateUsageModel(threadID: thread, model: model)
            }
            guard event.method == "thread/tokenUsage/updated" else { return }
            guard let thread = event.params["threadId"]?.string, let turn = event.params["turnId"]?.string,
                  let total = Self.tokens(event.params["tokenUsage"]?["total"]),
                  let last = Self.tokens(event.params["tokenUsage"]?["last"]) else { throw ManagerError.invalid("Codex usage notification is missing counters or identity") }
            _ = try await store.recordUsage(threadID: thread, turnID: turn, total: total, last: last)
        } catch {
            // Accounting must not turn otherwise successful work into a failed task.
            try? await store.record(taskID: taskID, kind: "usage.tracking.failed", detail: String(describing: error))
        }
    }
    private static func tokens(_ value: JSONValue?) -> TokenUsage? {
        guard let value, let input = value["inputTokens"]?.integer, let output = value["outputTokens"]?.integer,
              let total = value["totalTokens"]?.integer else { return nil }
        return TokenUsage(inputTokens: input, cachedInputTokens: value["cachedInputTokens"]?.integer ?? 0,
            cacheWriteInputTokens: value["cacheWriteInputTokens"]?.integer ?? 0, outputTokens: output,
            reasoningOutputTokens: value["reasoningOutputTokens"]?.integer ?? 0, totalTokens: total)
    }
}
