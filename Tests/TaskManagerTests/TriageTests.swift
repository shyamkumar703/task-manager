import CodexTransport
import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private func triageRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-manager-triage-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

private func eventually(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ManagerError.invalid("Triage condition timed out")
}

@Test func semanticRouteIsAtomicDeduplicatedAndLearnsThreadAssociation() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Title validation", repository: root, kind: .mock)
    try await store.transition(task.id, to: .paused)
    let event = SourceEvent(integration: "slack", sourceID: "message:1", revision: "1", associationKey: "slack:thread:7", body: "Also reject tabs", url: "https://example.invalid/thread/7")
    #expect(try await store.ingest([event, event], repository: root) == 1)
    let claimed = try #require(await store.claimTriageEvent())
    let decision = TriageDecision(action: .route, taskID: task.id, reason: "Adds another title validation case")
    #expect(try await store.applyTriage(eventID: claimed.id, decision: decision))
    #expect(try await store.applyTriage(eventID: claimed.id, decision: decision) == false)
    let reopened = try Store(path: root + "/state.sqlite")
    #expect(try await reopened.messages(taskID: task.id).count == 1)
    #expect(try await reopened.task(task.id).status == .paused)
    let routed = try await reopened.source(claimed.id)
    #expect(routed.reason == decision.reason)
    #expect(routed.messageDelivered == false)
    #expect(routed.taskID == task.id)
    #expect(routed.workerKind == .codex)
    #expect(routed.targetWorkerKind == .mock)
    let followup = SourceEvent(integration: "slack", sourceID: "message:2", revision: "1", associationKey: event.associationKey, body: "And newlines", url: event.url)
    try await reopened.ingest([followup], repository: root)
    #expect(try await reopened.routeKnownEvents() == 0)
    #expect(try await reopened.messages(taskID: task.id).count == 1)
    let reviewed = try #require(await reopened.claimTriageEvent())
    try await reopened.applyTriage(eventID: reviewed.id, decision: decision)
    #expect(try await reopened.routeKnownEvents() == 0)
    #expect(try await reopened.messages(taskID: task.id).count == 2)
    #expect(try await reopened.claimTriageEvent() == nil)
}

@Test func creatingWorkAndIgnoringChatterAreDurableAndIdempotent() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "Add a todo export command", repository: root, workerKind: .mock)
    _ = try await store.claimTriageEvent()
    let decision = TriageDecision(action: .create, goal: "Implement todo export", reason: "Distinct actionable feature")
    #expect(try await store.applyTriage(eventID: id, decision: decision))
    #expect(try await store.applyTriage(eventID: id, decision: decision) == false)
    let created = try await store.source(id)
    let taskID = try #require(created.taskID)
    #expect(created.disposition == .created)
    #expect(try await store.tasks().count == 1)
    #expect(try await store.agentSession(taskID: taskID)?.kind == .mock)
    #expect(try await store.messages(taskID: taskID).count == 1)
    let chatter = try await store.injectSource(body: "Thanks, have a good weekend!", repository: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: chatter, decision: .init(action: .ignore, reason: "Social chatter requires no work"))
    #expect(try await store.source(chatter).disposition == .ignored)
    #expect(try await store.tasks().count == 1)
}

@Test func clarificationPersistsAndIsDeliveredWithTheOriginalSource() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "Can you fix that validation?", repository: root, workerKind: .mock)
    let event = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: id, decision: .init(action: .clarify, reason: "Validation target is ambiguous", question: "Which command needs validation?"))
    #expect(try await store.tasks().isEmpty)
    let reopened = try Store(path: root + "/state.sqlite")
    #expect(try await reopened.source(id).question == "Which command needs validation?")
    try await reopened.answerSource(eventID: id, text: "The add command's title", expectedAttempt: event.attempts)
    await #expect(throws: ManagerError.self) { try await reopened.answerSource(eventID: id, text: "Duplicate answer") }
    #expect(try await reopened.source(id).disposition == .pending)
    #expect(try await reopened.source(id).clarification?.contains("The add command's title") == true)
    _ = try await reopened.claimTriageEvent()
    try await reopened.applyTriage(eventID: id, decision: .init(action: .create, goal: "Validate add command titles", reason: "User clarified the affected command"))
    let taskID = try #require(await reopened.source(id).taskID)
    let messages = try await reopened.messages(taskID: taskID)
    #expect(messages.count == 1)
    #expect(messages[0].body.contains("Can you fix that validation?"))
    #expect(messages[0].body.contains("The add command's title"))
}

@Test func invalidAndCrossRepositoryTargetsHaveNoPartialEffects() async throws {
    let root = try triageRoot(), other = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: other) }
    let store = try Store(path: root + "/state.sqlite")
    let foreign = try await store.createAgentTask(goal: "Other repo task", repository: other, kind: .mock)
    let archived = try await store.createAgentTask(goal: "Archived task", repository: root, kind: .mock)
    try await store.archive(archived.id)
    let id = try await store.injectSource(body: "Update this repo", repository: root)
    _ = try await store.claimTriageEvent()
    await #expect(throws: ManagerError.self) { try await store.applyTriage(eventID: id, decision: .init(action: .route, taskID: foreign.id, reason: "Wrong repo")) }
    await #expect(throws: ManagerError.self) { try await store.applyTriage(eventID: id, decision: .init(action: .route, taskID: "invented-id", reason: "Invented target")) }
    #expect(try await store.source(id).disposition == .triaging)
    #expect(try await store.messages(taskID: foreign.id).isEmpty)
    #expect(try await store.triageCandidates(repository: root).isEmpty)
    try await store.applyTriage(eventID: id, decision: .init(action: .route, taskID: archived.id, reason: "Stale decision"))
    #expect(try await store.source(id).disposition == .waitingForUser)
    #expect(try await store.messages(taskID: archived.id).isEmpty)
}

@Test func archivedThreadNeedsClarificationAndCanStartExplicitlySeparateWork() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let first = try await store.injectSource(body: "Implement export", repository: root, workerKind: .mock, associationKey: "thread:1")
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: first, decision: .init(action: .create, goal: "Export", reason: "New work"))
    let archived = try #require(await store.source(first).taskID)
    try await store.archive(archived)
    let next = try await store.injectSource(body: "Add JSON support", repository: root, workerKind: .mock, associationKey: "thread:1")
    #expect(try await store.routeKnownEvents() == 0)
    #expect(try await store.source(next).disposition == .waitingForUser)
    try await store.answerSource(eventID: next, text: "Start a separate JSON export task")
    #expect(try await store.routeKnownEvents() == 0)
    #expect(try await store.source(next).disposition == .pending)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: next, decision: .init(action: .create, goal: "JSON export", reason: "User requested separate work"))
    let replacement = try #require(await store.source(next).taskID)
    #expect(replacement != archived)
    let followup = try await store.injectSource(body: "Use UTF-8", repository: root, associationKey: "thread:1")
    #expect(try await store.routeKnownEvents() == 0)
    #expect(try await store.source(followup).disposition == .pending)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: followup, decision: .init(action: .route, taskID: replacement, reason: "Compatible encoding requirement"))
    #expect(try await store.source(followup).taskID == replacement)
    #expect(try await store.task(archived).archivedAt != nil)
}

@Test func interruptedTriageRecoversAndFailuresBackOffWithoutLosingEvents() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "Investigate validation", repository: root)
    let now = Date()
    _ = try await store.claimTriageEvent(now: now)
    let reopened = try Store(path: root + "/state.sqlite")
    try await reopened.recoverTriage()
    #expect(try await reopened.source(id).disposition == .pending)
    #expect(try await reopened.applyTriage(eventID: id, decision: .init(action: .create, goal: "Stale result", reason: "Old master result")) == false)
    for attempt in 0..<3 {
        let time = now.addingTimeInterval(Double(attempt * 20))
        #expect(try await reopened.claimTriageEvent(now: time)?.id == id)
        try await reopened.failTriage(id, error: "Temporary model error", now: time)
        #expect(try await reopened.claimTriageEvent(now: time) == nil)
    }
    #expect(try await reopened.source(id).disposition == .failed)
    #expect(try await reopened.tasks().isEmpty)
    try await reopened.retrySource(id)
    #expect(try await reopened.claimTriageEvent(now: now)?.id == id)
    try await reopened.ignoreSource(id)
    #expect(try await reopened.applyTriage(eventID: id, decision: .init(action: .create, goal: "Late result", reason: "Cancelled inference")) == false)
    #expect(try await reopened.tasks().isEmpty)
}

private actor ScriptedTriage: TriageEngine {
    let decisions: [TriageDecision]
    var calls = 0
    var lastCandidates: [TriageCandidate] = []
    init(_ decisions: [TriageDecision]) { self.decisions = decisions }
    func decide(event: IncomingSource, candidates: [TriageCandidate]) async throws -> TriageDecision {
        lastCandidates = candidates
        let result = decisions[min(calls, decisions.count - 1)]
        calls += 1
        return result
    }
}

@Test func sourceRouteReachesAnInProgressWorkerThroughTheActualInboxPipeline() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Title validation", repository: root, kind: .mock)
    let engine = ScriptedTriage([.init(action: .route, taskID: task.id, reason: "Adds a validation case")])
    let coordinator = Coordinator(store: store, stateDirectory: root, mockInterval: .milliseconds(70), triageEngine: engine)
    try await coordinator.tick()
    let source = try await store.injectSource(body: "Reject whitespace-only titles too", repository: root)
    try await eventually {
        try await coordinator.tick()
        return try await store.source(source).messageDelivered == true
    }
    #expect(try await store.source(source).taskID == task.id)
    #expect(try await store.outputs(taskID: task.id).contains { $0.text.contains("applied follow-up:") && $0.text.contains("Reject whitespace-only titles too") })
    #expect(await engine.lastCandidates.map(\.id) == [task.id])
    #expect(try await store.tasks().count == 1)
    await coordinator.shutdown()
}

@Test func masterClarificationDoesNotBlockTriageOfOtherEvents() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let first = try await store.injectSource(body: "Fix that thing", repository: root)
    let second = try await store.injectSource(body: "Thanks!", repository: root)
    let engine = ScriptedTriage([.init(action: .clarify, reason: "Missing target", question: "Which thing?"), .init(action: .ignore, reason: "Social chatter")])
    let triage = SourceTriage(store: store, engine: engine)
    try await eventually {
        try await triage.tick()
        return try await store.source(second).disposition == .ignored
    }
    #expect(try await store.source(first).disposition == .waitingForUser)
    #expect(await engine.calls == 2)
    await triage.shutdown()
}

private actor FakeMasterConnection: AgentConnection {
    nonisolated let events: AsyncStream<CodexClient.Event>
    private let continuation: AsyncStream<CodexClient.Event>.Continuation
    let finalText: String?
    var threadParams: JSONValue?
    init(finalText: String?) {
        let pair = AsyncStream<CodexClient.Event>.makeStream()
        events = pair.stream; continuation = pair.continuation; self.finalText = finalText
    }
    func connect() {}
    func request(_ method: String, params: JSONValue) -> JSONValue {
        if method == "thread/start" {
            threadParams = params
            return .object(["thread": .object(["id": .string("master-1")])])
        }
        if let finalText {
            continuation.yield(.init(method: "item/completed", params: .object(["threadId": .string("master-1"), "item": .object(["type": .string("agentMessage"), "text": .string(finalText)])])))
            continuation.yield(.init(method: "turn/completed", params: .object(["threadId": .string("master-1"), "turn": .object(["status": .string("completed")])])))
        }
        return .object(["turn": .object(["id": .string("master-turn")])])
    }
    func stop() { continuation.finish() }
}

@Test func codexMasterUsesStructuredReadOnlyJudgmentAndBoundedTimeout() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let id = try await store.injectSource(body: "Thanks!", repository: root)
    let event = try await store.source(id)
    let connection = FakeMasterConnection(finalText: "{\"action\":\"ignore\",\"reason\":\"Social chatter\",\"taskID\":null,\"goal\":null,\"question\":null}")
    let master = CodexMasterTriage(stateDirectory: root, factory: { connection })
    let result = try await master.decide(event: event, candidates: [])
    #expect(result.action == .ignore)
    #expect(await connection.threadParams?["sandbox"] == .string("read-only"))
    #expect(await connection.threadParams?["config"]?["features.shell_tool"] == .bool(false))
    let silent = FakeMasterConnection(finalText: nil)
    let bounded = CodexMasterTriage(stateDirectory: root, timeout: .milliseconds(30), factory: { silent })
    await #expect(throws: (any Error).self) { try await bounded.decide(event: event, candidates: []) }
    let malformed = FakeMasterConnection(finalText: "not-json")
    let invalid = CodexMasterTriage(stateDirectory: root, factory: { malformed })
    await #expect(throws: (any Error).self) { try await invalid.decide(event: event, candidates: []) }
}

@Test func triageSchemaUpgradePreservesV3TaskHistoryAndManualOwnership() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite"
    let store = try Store(path: path)
    let task = try await store.createAgentTask(goal: "Keep my terminal", repository: root, kind: .codex)
    try await store.setWorkspace(taskID: task.id, path: root)
    try await store.setThread(taskID: task.id, threadID: "persisted-thread")
    _ = try await store.claimTerminal(taskID: task.id)
    let sqlite = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
    let fixture = try await sqlite.run(arguments: [path, "DROP TABLE source_links; DROP TABLE event_context; PRAGMA user_version = 3;"])
    #expect(fixture.exitCode == 0)
    let upgraded = try Store(path: path)
    #expect(try await upgraded.task(task.id).status == .paused)
    #expect(try await upgraded.agentSession(taskID: task.id)?.manualActive == true)
    #expect(try await upgraded.agentSession(taskID: task.id)?.threadID == "persisted-thread")
    let id = try await upgraded.injectSource(body: "New update", repository: root)
    #expect(try await upgraded.source(id).disposition == .pending)
    try await upgraded.releaseTerminal(taskID: task.id)
}

@Test func instructionAndApproachConflictsWaitForDurableUserResolution() async throws {
    let root = try triageRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    for accept in [true, false] {
        let path = root + (accept ? "/accept.sqlite" : "/reject.sqlite")
        let store = try Store(path: path)
        let task = try await store.createAgentTask(goal: "Use Swift; preserve the existing CLI", repository: root, kind: .mock)
        try await store.transition(task.id, to: .paused)
        let body = accept ? "Rewrite in Python" : "Replace the CLI with a web app"
        let id = try await store.injectSource(body: body, repository: root)
        _ = try await store.claimTriageEvent()
        try await store.applyTriage(eventID: id, decision: .init(action: .conflict, taskID: task.id,
            reason: "Incoming proposal conflicts with current instructions or approach",
            question: "Keep the current approach or adopt: \(body)?"))
        let reopened = try Store(path: path)
        try await reopened.recoverTriage()
        #expect(try await reopened.source(id).disposition == .waitingForUser)
        #expect(try await reopened.source(id).taskID == task.id)
        #expect(try await reopened.messages(taskID: task.id).isEmpty)
        #expect(try await reopened.task(task.id).status == .paused)
        #expect(try await reopened.claimTriageEvent() == nil)
        let answer = accept ? "Adopt the proposed change" : "Keep the current approach; ignore this proposal"
        try await reopened.answerSource(eventID: id, text: answer)
        _ = try await reopened.claimTriageEvent()
        let decision = accept
            ? TriageDecision(action: .route, taskID: task.id, reason: "User accepted the change")
            : TriageDecision(action: .ignore, reason: "User rejected the change")
        try await reopened.applyTriage(eventID: id, decision: decision)
        let messages = try await reopened.messages(taskID: task.id)
        #expect(messages.count == (accept ? 1 : 0))
        if accept { #expect(messages[0].body.contains(answer)) }
        let candidates = try await reopened.triageCandidates(repository: root)
        #expect(candidates[0].recentContext.contains { $0.contains(answer) })
    }
}
