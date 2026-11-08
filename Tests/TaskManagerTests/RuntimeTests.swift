import CodexTransport
import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import TaskManagerTUI
import Testing

private func runtimeDirectory() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("task-manager-runtime-\(UUID())").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func until(_ description: String, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ManagerError.invalid("Timed out waiting for \(description)")
}

private func gitRepository(at path: String) async throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let git = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git"))
    for arguments in [["init", "-b", "main", path], ["-C", path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Initial fixture"]] {
        let result = try await git.run(arguments: arguments)
        #expect(result.exitCode == 0)
    }
}

@Test func durableAgentRecordsRecoveryAndTranscripts() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite"
    let store = try Store(path: path)
    let task = try await store.createAgentTask(goal: "Investigate", repository: root, kind: .codex)
    try await store.transition(task.id, to: .running)
    try await store.setWorkspace(taskID: task.id, path: root + "/workspace")
    try await store.setThread(taskID: task.id, threadID: "thread-fixture")
    try await store.setTurn(taskID: task.id, turnID: "turn-fixture")
    try await store.writeOutput(taskID: task.id, itemID: "stream", kind: "assistant", text: "hello")
    try await store.writeOutput(taskID: task.id, itemID: "stream", kind: "assistant", text: " world", append: true)
    let message = try await store.addMessage(taskID: task.id, body: "New instructions")
    let reopened = try Store(path: path)
    #expect(try await reopened.recoverAgentSessions() == 1)
    #expect(try await reopened.task(task.id).status == .paused)
    let session = try #require(await reopened.agentSession(taskID: task.id))
    #expect(session.threadID == "thread-fixture")
    #expect(session.turnID == nil)
    #expect(session.workspace == root + "/workspace")
    #expect(try await reopened.messages(taskID: task.id, pendingOnly: true).map(\.id) == [message])
    #expect(try await reopened.outputs(taskID: task.id).contains { $0.text == "hello world" })
}

@Test func coordinatorLockHasOneOwner() throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    #expect(!CoordinatorLock.isRunning(stateDirectory: root))
    do {
        let owner = try CoordinatorLock(stateDirectory: root)
        #expect(CoordinatorLock.isRunning(stateDirectory: root))
        #expect(throws: ManagerError.self) { try CoordinatorLock(stateDirectory: root) }
        withExtendedLifetime(owner) {}
    }
    #expect(!CoordinatorLock.isRunning(stateDirectory: root))
}

@Test func mockWorkersAcceptFollowUpsAndWaitWithoutBlockingPeers() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let first = try await store.createAgentTask(goal: "First", repository: root, kind: .mock)
    let second = try await store.createAgentTask(goal: "Second", repository: root, kind: .mock)
    let coordinator = Coordinator(store: store, stateDirectory: root, mockInterval: .milliseconds(25))
    try await coordinator.tick()
    try await until("workers running") {
        let a = try await store.task(first.id).status
        let b = try await store.task(second.id).status
        return a == .running && b == .running
    }
    let message = try await store.addMessage(taskID: first.id, body: "Prioritize empty titles")
    try await until("message applied") { try await store.messages(taskID: first.id).contains { $0.id == message && $0.delivered } }
    #expect(try await store.outputs(taskID: first.id).contains { $0.text.contains("applied follow-up: Prioritize empty titles") })
    try await until("questions") { try await store.questions().count == 2 }
    let question = try #require(await store.questions().first { $0.taskID == first.id })
    try await store.answer(questionID: question.id, text: "Reject whitespace too")
    try await coordinator.tick()
    try await until("first completed") { try await store.task(first.id).status == .completed }
    #expect(try await store.task(second.id).status == .waitingForUser)
    #expect(try await store.messages(taskID: first.id, pendingOnly: true).isEmpty)
    await coordinator.shutdown()
}

private actor FakeAgent: AgentConnection {
    nonisolated let events: AsyncStream<CodexClient.Event>
    private let continuation: AsyncStream<CodexClient.Event>.Continuation
    private(set) var methods: [String] = []
    private(set) var steered: JSONValue?
    let raceOnSteer: Bool

    init(raceOnSteer: Bool = false) {
        let pair = AsyncStream<CodexClient.Event>.makeStream()
        events = pair.stream; continuation = pair.continuation
        self.raceOnSteer = raceOnSteer
    }
    func connect() {}
    func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        methods.append(method)
        switch method {
        case "thread/start", "thread/resume": return .object(["thread": .object(["id": .string("thread-1")])])
        case "turn/start": return .object(["turn": .object(["id": .string("turn-1")])])
        case "turn/steer":
            steered = params
            if raceOnSteer {
                complete()
                try await Task.sleep(for: .milliseconds(20))
                throw TransportError.remote(code: -32600, message: "No active turn")
            }
            return .object(["turnId": .string("turn-1")])
        default: return .object([:])
        }
    }
    func complete() {
        continuation.yield(.init(method: "item/completed", params: .object([
            "threadId": .string("thread-1"), "item": .object([
                "id": .string("final"), "type": .string("agentMessage"),
                "text": .string("{\"status\":\"completed\",\"text\":\"Verified fixture\"}"),
            ]),
        ])))
        continuation.yield(.init(method: "turn/completed", params: .object([
            "threadId": .string("thread-1"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")]),
        ])))
    }
    func stop() { continuation.finish() }
}

@Test func liveDriverSteersTheActiveTurnAndAcknowledgesAfterAcceptance() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = root + "/repo"
    try await gitRepository(at: repository)
    let store = try Store(path: root + "/state.sqlite")
    let fake = FakeAgent()
    let coordinator = Coordinator(store: store, stateDirectory: root, factory: { fake })
    let task = try await store.createAgentTask(goal: "Investigate", repository: repository, kind: .codex)
    try await coordinator.tick()
    try await until("active turn") { try await store.agentSession(taskID: task.id)?.turnID == "turn-1" }
    let message = try await store.addMessage(taskID: task.id, body: "Use a different approach")
    try await coordinator.tick()
    try await until("accepted steering") { try await store.messages(taskID: task.id).contains { $0.id == message && $0.delivered } }
    #expect(await fake.steered?["expectedTurnId"] == .string("turn-1"))
    await fake.complete()
    try await until("completion") { try await store.task(task.id).status == .completed }
    #expect(try await store.agentSession(taskID: task.id)?.workspace != repository)
    await coordinator.shutdown()
}

@Test func steerCompletionRaceRetainsMessageForNextTurn() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = root + "/repo"
    try await gitRepository(at: repository)
    let store = try Store(path: root + "/state.sqlite")
    let fake = FakeAgent(raceOnSteer: true)
    let coordinator = Coordinator(store: store, stateDirectory: root, factory: { fake })
    let task = try await store.createAgentTask(goal: "Investigate", repository: repository, kind: .codex)
    try await coordinator.tick()
    try await until("active turn") { try await store.agentSession(taskID: task.id)?.turnID == "turn-1" }
    let message = try await store.addMessage(taskID: task.id, body: "Arriving as turn ends")
    try await coordinator.tick()
    try await until("continuation queued") { try await store.task(task.id).status == .queued }
    #expect(try await store.messages(taskID: task.id, pendingOnly: true).map(\.id) == [message])
    await coordinator.shutdown()
}

@Test func terminalFormattingHidesOutcomeProtocolAndStripsControls() {
    #expect(TerminalText.assistantText("{\"status\":\"question\",\"text\":\"Which command?\"}") == "Which command?")
    #expect(TerminalText.assistantText("{\"status\":") == "Writing response…")
    #expect(!TerminalText.clean("hello\u{1B}[31m\u{07}world").contains("\u{1B}"))
    #expect(TerminalText.wrap("abcd\nef", width: 3) == ["abc", "d", "ef"])
}
