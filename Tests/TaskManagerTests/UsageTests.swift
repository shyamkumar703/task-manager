import CodexTransport
import Foundation
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
@testable import TaskManagerTUI
import Testing

private func usageDirectory() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("task-manager-usage-\(UUID())").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func usageHighWaterMarkSurvivesDuplicatesOutOfOrderEventsAndRestart() async throws {
    let root = try usageDirectory(); defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite"
    let store = try Store(path: path)
    let task = try await store.createAgentTask(goal: "Track cost", repository: root, kind: .codex)
    try await store.registerUsageThread(threadID: "t", taskID: task.id, role: "implementation", model: "gpt-6.1-sol", provider: "openai", effort: "high")
    let first = TokenUsage(inputTokens: 100, cachedInputTokens: 40, outputTokens: 10, reasoningOutputTokens: 5)
    let second = TokenUsage(inputTokens: 200, cachedInputTokens: 80, outputTokens: 20, reasoningOutputTokens: 10)
    #expect(try await store.recordUsage(threadID: "t", turnID: "one", total: first, last: first))
    #expect(try await store.recordUsage(threadID: "t", turnID: "one", total: first, last: first) == false)
    #expect(try await store.recordUsage(threadID: "t", turnID: "one", total: second, last: first))
    #expect(try await store.recordUsage(threadID: "t", turnID: "one", total: first, last: first) == false)
    let reopened = try Store(path: path)
    try await reopened.registerUsageThread(threadID: "t", taskID: task.id, role: "implementation", model: "gpt-6.1-sol", provider: "openai", resumed: true)
    #expect(try await reopened.recordUsage(threadID: "t", turnID: "one", total: second, last: first) == false)
    let third = TokenUsage(inputTokens: 300, cachedInputTokens: 120, outputTokens: 30, reasoningOutputTokens: 15)
    try await reopened.recordUsage(threadID: "t", turnID: "two", total: third, last: first)
    let report = try await reopened.usage(taskID: task.id)
    #expect(report.records.count == 2)
    #expect(report.totalTokens == 330)
    #expect(abs(report.estimatedUSD - 0.000672) < 0.00000001)
    #expect(report.unpricedRecords == 0)
    try await reopened.archive(task.id)
    #expect(try await reopened.usage().totalTokens == 330)
}

@Test func firstResumedUsageExcludesPreviouslyUntrackedThreadHistory() async throws {
    let store = try Store(path: ":memory:")
    try await store.registerUsageThread(threadID: "old", role: "exploration", model: nil, provider: nil, resumed: true)
    let total = TokenUsage(inputTokens: 10000, outputTokens: 1000)
    let last = TokenUsage(inputTokens: 100, outputTokens: 10)
    try await store.recordUsage(threadID: "old", turnID: "new", total: total, last: last)
    #expect(try await store.usage().totalTokens == 110)
    #expect(try await store.usage().records.first?.estimatedUSD == nil)
    #expect(UsagePresentation.compact(try await store.usage()).contains("cost unknown"))
}

@Test func usagePricingHandlesCachedAndReasoningTokensWithoutDoubleCounting() throws {
    let price = UsagePrice(input: 2, cachedInput: 0.2, output: 10, source: "fixture")
    let tokens = TokenUsage(inputTokens: 1_000_000, cachedInputTokens: 400_000, outputTokens: 100_000, reasoningOutputTokens: 80_000)
    #expect(abs(try #require(price.estimate(tokens)) - 2.28) < 0.000001)
    #expect(price.estimate(.init(inputTokens: 100, cacheWriteInputTokens: 20, outputTokens: 10)) == nil)
}

@Test func unknownPricesCanBeConfiguredWithoutRepricingExistingSnapshots() async throws {
    let store = try Store(path: ":memory:")
    try await store.registerUsageThread(threadID: "t", role: "triage", model: "custom-model", provider: "custom")
    let first = TokenUsage(inputTokens: 100, outputTokens: 10)
    try await store.recordUsage(threadID: "t", turnID: "one", total: first, last: first)
    #expect(try await store.usage().unpricedRecords == 1)
    try await store.setUsagePrice(model: "custom-model", provider: "custom", price: .init(input: 1, cachedInput: 0.1, output: 2, source: "first rate"))
    let priced = try await store.usage()
    #expect(abs(priced.estimatedUSD - 0.00012) < 0.00000001)
    try await store.setUsagePrice(model: "custom-model", provider: "custom", price: .init(input: 10, cachedInput: 1, output: 20, source: "next rate"))
    #expect(try await store.usage().estimatedUSD == priced.estimatedUSD)
    try await store.recordUsage(threadID: "t", turnID: "two", total: .init(inputTokens: 200, outputTokens: 20), last: first)
    #expect(abs(try await store.usage().estimatedUSD - 0.00132) < 0.00000001)
}

@Test func unsupportedPricingAndInvalidCountersNeverLookFree() async throws {
    let store = try Store(path: ":memory:")
    for (id, tier, write, input) in [("tier", "priority", Int64(0), Int64(100)), ("write", "default", 20, 100), ("long", "default", 0, 300000)] {
        try await store.registerUsageThread(threadID: id, role: "triage", model: "gpt-6.1-sol", provider: "openai", serviceTier: tier)
        let tokens = TokenUsage(inputTokens: input, cacheWriteInputTokens: write, outputTokens: 10)
        try await store.recordUsage(threadID: id, turnID: "turn", total: tokens, last: tokens)
    }
    let report = try await store.usage()
    #expect(report.unpricedRecords == 3)
    #expect(report.records.allSatisfy { $0.estimatedUSD == nil })
    #expect(UsagePresentation.sections(report).first?.text.contains("cost: unknown") == true)
    #expect(throws: ManagerError.self) { try TokenUsage(inputTokens: -1, outputTokens: 0).validate() }
    #expect(throws: ManagerError.self) { try TokenUsage(inputTokens: 10, cachedInputTokens: 20, outputTokens: 1).validate() }
    await #expect(throws: ManagerError.self) { try await store.setUsagePrice(model: "bad", price: .init(input: .nan, cachedInput: 0, output: 0, source: "invalid")) }
}

private actor UsageFixtureConnection: AgentConnection {
    nonisolated let events: AsyncStream<CodexClient.Event>
    let continuation: AsyncStream<CodexClient.Event>.Continuation
    let reroute: Bool
    init(reroute: Bool = false) { self.reroute = reroute; let pair = AsyncStream<CodexClient.Event>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func connect() {}
    func stop() { continuation.finish() }
    func request(_ method: String, params: JSONValue) -> JSONValue {
        if method == "thread/start" { return .object(["thread": .object(["id": .string("fixture")]), "model": .string("gpt-6.1-sol"), "modelProvider": .string("openai")]) }
        if method == "turn/start" {
            let tokens: JSONValue = .object(["inputTokens": .integer(100), "cachedInputTokens": .integer(50), "outputTokens": .integer(10), "reasoningOutputTokens": .integer(5), "totalTokens": .integer(110)])
            let event = CodexClient.Event(method: "thread/tokenUsage/updated", params: .object(["threadId": .string("fixture"), "turnId": .string("turn"), "tokenUsage": .object(["total": tokens, "last": tokens])]))
            continuation.yield(event); continuation.yield(event)
            if reroute {
                continuation.yield(.init(method: "model/rerouted", params: .object(["threadId": .string("fixture"), "toModel": .string("gpt-6-luna")])))
                let total: JSONValue = .object(["inputTokens": .integer(200), "cachedInputTokens": .integer(100), "outputTokens": .integer(20), "reasoningOutputTokens": .integer(10), "totalTokens": .integer(220)])
                continuation.yield(.init(method: "thread/tokenUsage/updated", params: .object(["threadId": .string("fixture"), "turnId": .string("turn"), "tokenUsage": .object(["total": total, "last": tokens])])) )
            }
            continuation.yield(.init(method: "turn/completed", params: .object(["threadId": .string("fixture"), "turn": .object(["id": .string("turn"), "status": .string("failed")])])))
        }
        return .object([:])
    }
}

@Test func reroutedModelUsageKeepsPreviousModelPriceAndSourceAttribution() async throws {
    let root = try usageDirectory(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let source = try await store.injectSource(body: "Cost fixture", repository: root)
    let connection = UsageTrackingConnection(base: UsageFixtureConnection(reroute: true), store: store, role: "discovery", sourceEventID: source)
    try await connection.connect()
    _ = try await connection.request("thread/start", params: .object([:]))
    _ = try await connection.request("turn/start", params: .object([:]))
    for await event in connection.events { if event.method == "turn/completed" { break } }
    let report = try await store.usage(sourceEventID: source)
    #expect(report.totalTokens == 220)
    #expect(Set(report.records.map(\.model)) == ["gpt-6.1-sol", "gpt-6-luna"])
    #expect(abs(report.estimatedUSD - 0.0002155) < 0.00000001)
    await connection.stop()
}

@Test func usageConnectionPersistsBeforeForwardingFailedCompletion() async throws {
    let store = try Store(path: ":memory:")
    let connection = UsageTrackingConnection(base: UsageFixtureConnection(), store: store, role: "triage")
    try await connection.connect()
    _ = try await connection.request("thread/start", params: .object([:]))
    _ = try await connection.request("turn/start", params: .object([:]))
    for await event in connection.events {
        if event.method == "turn/completed" { break }
    }
    #expect(try await store.usage().totalTokens == 110)
    #expect(try await store.usage().records.count == 1)
    #expect(try await store.usage().forRole("triage").hasUsage)
    await connection.stop()
}

@Test func usageDashboardDistinguishesNoTelemetryAndPartialCost() throws {
    #expect(UsagePresentation.compact(.init()) == "Usage: not recorded")
    let records = [UsageRecord(threadID: "t", turnID: "one", taskID: nil, sourceEventID: nil, role: "discovery", model: "unknown", provider: "unknown", reasoningEffort: nil, tokens: .init(inputTokens: 10, outputTokens: 1), estimatedUSD: nil, priceSource: nil, updatedAt: "now"), UsageRecord(threadID: "t2", turnID: "two", taskID: nil, sourceEventID: nil, role: "triage", model: "known", provider: "openai", reasoningEffort: "high", tokens: .init(inputTokens: 100, outputTokens: 10), estimatedUSD: 0.01, priceSource: "fixture", updatedAt: "now")]
    let report = UsageReport(records: records)
    #expect(UsagePresentation.compact(report).contains("+ unpriced"))
    #expect(UsagePresentation.sections(report).first?.text.contains("priced portion only") == true)
    #expect(report.forRole("triage").totalTokens == 110)
    #expect(report.forRole("discovery").unpricedRecords == 1)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(UsageReport())) as? [String: Any])
    #expect(json["estimatedUSD"] is NSNull)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_USAGE"] == "1"))
func liveCodexUsageNotificationMatchesInstalledProtocol() async throws {
    let store = try Store(path: ":memory:")
    let connection = UsageTrackingConnection(base: CodexConnection(), store: store, role: "triage")
    do {
        try await connection.connect()
        let response = try await connection.request("thread/start", params: .object([
            "ephemeral": .bool(true), "sandbox": .string("read-only"), "approvalPolicy": .string("never"),
            "config": .object(["features.apps": .bool(false), "features.shell_tool": .bool(false), "features.unified_exec": .bool(false), "web_search": .string("disabled"), "mcp_servers": .object([:])]),
        ]))
        let threadID = try #require(response["thread"]?["id"]?.string)
        _ = try await connection.request("turn/start", params: .object(["threadId": .string(threadID), "input": .array([.object(["type": .string("text"), "text": .string("Reply with exactly OK. Do not use tools.")])])]))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in connection.events {
                    if event.method == "turn/completed" { return }
                }
                throw ManagerError.invalid("Usage smoke connection ended before completion")
            }
            group.addTask { try await Task.sleep(for: .seconds(60)); throw ManagerError.invalid("Usage smoke timed out") }
            _ = try await group.next(); group.cancelAll()
        }
        let report = try await store.usage()
        #expect(report.totalTokens > 0)
        #expect(report.records.first?.model != "unknown")
        #expect(report.records.first?.provider != "unknown")
        print("Live usage: \(UsagePresentation.compact(report)); model: \(report.records.first?.model ?? "missing")")
        await connection.stop()
    } catch { await connection.stop(); throw error }
}
