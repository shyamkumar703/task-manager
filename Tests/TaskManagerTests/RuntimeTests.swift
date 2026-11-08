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
    let completeOnStart: Bool
    nonisolated let remoteAddress: String?

    init(raceOnSteer: Bool = false, completeOnStart: Bool = false, shared: Bool = false) {
        remoteAddress = shared ? "unix:///tmp/test-shared-socket" : nil
        let pair = AsyncStream<CodexClient.Event>.makeStream()
        events = pair.stream; continuation = pair.continuation
        self.raceOnSteer = raceOnSteer
        self.completeOnStart = completeOnStart
    }
    func connect() {}
    func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        methods.append(method)
        switch method {
        case "thread/start", "thread/resume": return .object(["thread": .object(["id": .string("thread-1")])])
        case "turn/start":
            if completeOnStart {
                complete()
                try await Task.sleep(for: .milliseconds(30))
            }
            return .object(["turn": .object(["id": .string("turn-1")])])
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
    func interactiveStart() {
        continuation.yield(.init(method: "turn/started", params: .object([
            "threadId": .string("thread-1"), "turn": .object(["id": .string("interactive-2")]),
        ])))
    }
    func interactiveComplete() {
        continuation.yield(.init(method: "item/completed", params: .object([
            "threadId": .string("thread-1"), "item": .object([
                "id": .string("interactive-answer"), "type": .string("agentMessage"), "text": .string("Answer from the same live child"),
            ]),
        ])))
        continuation.yield(.init(method: "turn/completed", params: .object([
            "threadId": .string("thread-1"), "turn": .object(["id": .string("interactive-2"), "status": .string("completed")]),
        ])))
    }
    func stop() { methods.append("stop"); continuation.finish() }
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

@Test func worktreeRecoveryVerifiesOwnershipAndPreservesDirtyCheckout() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = root + "/repo"
    let other = root + "/other"
    try await gitRepository(at: repository)
    try await gitRepository(at: other)
    try Data("User's uncommitted content".utf8).write(to: URL(fileURLWithPath: repository + "/scratch.txt"))
    let workspaces = Workspaces(stateDirectory: root + "/state")
    let id = UUID().uuidString
    let workspace = try await workspaces.prepare(taskID: id, repository: repository)
    #expect(workspace != repository)
    #expect(try await workspaces.prepare(taskID: id, repository: repository) == workspace)
    await #expect(throws: ManagerError.self) { try await workspaces.prepare(taskID: id, repository: other) }
    #expect(try String(contentsOfFile: repository + "/scratch.txt", encoding: .utf8) == "User's uncommitted content")
    #expect(!FileManager.default.fileExists(atPath: workspace + "/scratch.txt"))
}

@Test func schemaOneMigratesWithoutLosingExistingTasks() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite"
    let first = try Store(path: path)
    let existing = try await first.createTask(goal: "Preserve existing task")
    let sqlite = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
    let result = try await sqlite.run(arguments: [path, "DROP TABLE source_links; DROP TABLE event_context; DROP TABLE agent_output; DROP TABLE agent_sessions; ALTER TABLE tasks DROP COLUMN archived_at; PRAGMA user_version = 1;"])
    #expect(result.exitCode == 0)
    let upgraded = try Store(path: path)
    #expect(try await upgraded.task(existing.id).goal == "Preserve existing task")
    let new = try await upgraded.createAgentTask(goal: "New agent task", repository: root, kind: .mock)
    #expect(try await upgraded.agentSession(taskID: new.id)?.kind == .mock)
}

@Test func pausingMockStopsProgressUntilResumed() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let coordinator = Coordinator(store: store, stateDirectory: root, mockInterval: .milliseconds(40))
    let task = try await store.createAgentTask(goal: "Pause me", repository: root, kind: .mock)
    try await coordinator.tick()
    try await until("first step") { try await store.agentSession(taskID: task.id)?.threadID == "mock:1" }
    try await store.transition(task.id, to: .paused)
    try await coordinator.tick()
    try await Task.sleep(for: .milliseconds(60))
    let step = try await store.agentSession(taskID: task.id)?.threadID
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await store.agentSession(taskID: task.id)?.threadID == step)
    #expect(try await store.task(task.id).status == .paused)
    try await store.resume(task.id)
    try await coordinator.tick()
    try await until("resumed progress") { try await store.agentSession(taskID: task.id)?.threadID != step }
    await coordinator.shutdown()
}

private final class FakeAgentQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [FakeAgent]
    init(_ agents: [FakeAgent]) { self.agents = agents }
    func next() -> any AgentConnection {
        lock.lock()
        defer { lock.unlock() }
        return agents.removeFirst()
    }
}

@Test func pauseInterruptsCodexAndResumeUsesSavedThreadWithEagerCompletion() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = root + "/repo"
    try await gitRepository(at: repository)
    let store = try Store(path: root + "/state.sqlite")
    let first = FakeAgent()
    let second = FakeAgent(completeOnStart: true)
    let queue = FakeAgentQueue([first, second])
    let coordinator = Coordinator(store: store, stateDirectory: root, factory: { queue.next() })
    let task = try await store.createAgentTask(goal: "Pause and continue", repository: repository, kind: .codex)
    try await coordinator.tick()
    try await until("first active turn") { try await store.agentSession(taskID: task.id)?.turnID == "turn-1" }
    try await store.transition(task.id, to: .paused)
    try await coordinator.tick()
    try await until("interruption persisted") { try await store.agentSession(taskID: task.id)?.turnID == nil }
    #expect(await first.methods.contains("turn/interrupt"))
    _ = try await store.addMessage(taskID: task.id, body: "Continue with this update")
    try await store.resume(task.id)
    try await until("resumed completion") {
        try await coordinator.tick()
        return try await store.task(task.id).status == .completed
    }
    #expect(await second.methods.contains("thread/resume"))
    #expect(try await store.agentSession(taskID: task.id)?.threadID == "thread-1")
    #expect(try await store.messages(taskID: task.id, pendingOnly: true).isEmpty)
    await coordinator.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_CODEX_TEST"] == "1"))
func sharedCodexClientsJoinExactlyTheSameLiveThread() async throws {
    let connection = CodexConnection(shared: true)
    let peer = CodexClient()
    do {
        try await connection.connect()
        let address = try #require(connection.remoteAddress)
        let response = try await connection.request("thread/start", params: .object([
            "cwd": .string(FileManager.default.currentDirectoryPath), "sandbox": .string("read-only"), "approvalPolicy": .string("never"),
        ]))
        let thread = try #require(response["thread"]?["id"]?.string)
        let initial = try await connection.request("turn/start", params: .object([
            "threadId": .string(thread), "input": .array([.object(["type": .string("text"), "text": .string("Reply OK. Do not use tools.")])]),
        ]))
        _ = try? await connection.request("turn/interrupt", params: .object(["threadId": .string(thread), "turnId": initial["turn"]?["id"] ?? .null]))
        for await event in connection.events where event.method == "turn/completed" { break }
        try await peer.connect(unixSocket: String(address.dropFirst("unix://".count)))
        _ = try await peer.initialize()
        let resumed = try await peer.request("thread/resume", params: .object(["threadId": .string(thread)]))
        #expect(resumed["thread"]?["id"]?.string == thread)
        let observer = Task {
            for await event in connection.events where event.method == "turn/started" {
                return event.params["threadId"]?.string
            }
            return nil as String?
        }
        let turn = try await peer.request("turn/start", params: .object([
            "threadId": .string(thread), "input": .array([.object(["type": .string("text"), "text": .string("Reply with exactly SHARED_THREAD_OK. Do not use tools.")])]),
        ]))
        #expect(turn["turn"]?["id"]?.string != nil)
        #expect(await observer.value == thread)
        _ = try? await peer.request("turn/interrupt", params: .object(["threadId": .string(thread), "turnId": turn["turn"]?["id"] ?? .null]))
        await peer.stop(); await connection.stop()
    } catch { await peer.stop(); await connection.stop(); throw error }
}

@Test func sharedWorkerStaysObservedBetweenTurnsAndSteersInteractiveTurns() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = root + "/repo"
    try await gitRepository(at: repository)
    let store = try Store(path: root + "/state.sqlite")
    let fake = FakeAgent(shared: true)
    let coordinator = Coordinator(store: store, stateDirectory: root, concurrency: 1, factory: { fake })
    let task = try await store.createAgentTask(goal: "Investigate", repository: repository, kind: .codex)
    try await coordinator.tick()
    try await until("initial turn") { try await store.agentSession(taskID: task.id)?.turnID == "turn-1" }
    await fake.complete()
    try await until("idle shared worker") {
        let session = try await store.agentSession(taskID: task.id)
        return try await store.task(task.id).status == .completed && session?.workerActive == false
    }
    await fake.interactiveStart()
    try await until("terminal turn observed") { try await store.agentSession(taskID: task.id)?.turnID == "interactive-2" }
    #expect(try await store.task(task.id).status == .running)
    let message = try await store.addMessage(taskID: task.id, body: "Relevant source follow-up")
    try await coordinator.tick()
    try await until("source forwarded to terminal turn") { try await store.messages(taskID: task.id).contains { $0.id == message && $0.delivered } }
    #expect(await fake.steered?["expectedTurnId"]?.string == "interactive-2")
    await fake.interactiveComplete()
    try await until("terminal result observed") { try await store.task(task.id).status == .completed }
    #expect(try await store.outputs(taskID: task.id).contains { $0.text == "Answer from the same live child" })
    _ = try await store.addMessage(taskID: task.id, body: "More work")
    try await coordinator.tick()
    try await until("manager continues same connection") { try await store.agentSession(taskID: task.id)?.turnID == "turn-1" }
    #expect(await fake.methods.filter { $0 == "thread/start" }.count == 1)
    #expect(await fake.methods.filter { $0 == "thread/resume" }.isEmpty)
    await fake.complete()
    try await until("idle before exclusive handoff") {
        let session = try await store.agentSession(taskID: task.id)
        return try await store.task(task.id).status == .completed && session?.workerActive == false
    }
    let terminal = Task { try await ManualTerminal.prepare(store: store, taskID: task.id, stateDirectory: root) }
    try await until("manual reservation") { try await store.agentSession(taskID: task.id)?.manualActive == true }
    try await coordinator.tick()
    _ = try await terminal.value
    #expect(await fake.methods.contains("stop"))
    #expect(!FileManager.default.fileExists(atPath: root + "/live-agents/" + task.id + ".json"))
    await coordinator.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_CODEX_TEST"] == "1"))
func liveTmuxWorkspaceUsesTheObservedChild() async throws {
    let root = try runtimeDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = root + "/repo with spaces"
    try await gitRepository(at: repository)
    let store = try Store(path: root + "/state.sqlite")
    let coordinator = Coordinator(store: store, stateDirectory: root)
    let task = try await store.createAgentTask(goal: "Return a completed result with text SHARED_INITIAL_OK. Do not use tools or change files.", repository: repository, kind: .codex)
    let runner = GHProcessRunner(executable: URL(fileURLWithPath: try TaskWorkspace.executable("tmux")))
    let loop = Task {
        while !Task.isCancelled { try await coordinator.tick(); try await Task.sleep(for: .milliseconds(50)) }
    }
    let name = "task-" + task.id.lowercased()
    do {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while ContinuousClock.now < deadline {
            let status = try await store.task(task.id).status
            if [.completed, .failed].contains(status) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await store.task(task.id).status == .completed)
        let record = try #require(await store.agentSession(taskID: task.id))
        let data = try Data(contentsOf: URL(fileURLWithPath: root + "/live-agents/" + task.id + ".json"))
        let workspace = try JSONDecoder().decode(TaskWorkspace.self, from: data)
        #expect(workspace.threadID == record.threadID)
        #expect(try await workspace.prepareTmux() == name)
        try await Task.sleep(for: .seconds(3))
        let windows = try await runner.run(arguments: ["list-windows", "-t", "=" + name, "-F", "#{window_name}|#{pane_current_path}"])
        let windowText = String(decoding: windows.stdout, as: UTF8.self)
        #expect(windowText.split(separator: "\n").count == 3)
        for title in ["editor", "codex", "shell"] { #expect(windowText.contains(title + "|" + workspace.workingDirectory)) }
        let capture = try await runner.run(arguments: ["capture-pane", "-p", "-t", "=" + name + ":codex"])
        if String(decoding: capture.stdout, as: UTF8.self).contains("Trust this folder?") {
            // The opt-in live test runs with an isolated CODEX_HOME, so accepting this
            // fixture never edits the developer's real folder-trust configuration.
            try #require(ProcessInfo.processInfo.environment["TASK_MANAGER_ISOLATED_CODEX_HOME"] == "1")
            _ = try await runner.run(arguments: ["send-keys", "-t", "=" + name + ":codex", "Enter"])
            try await Task.sleep(for: .seconds(3))
        }
        _ = try await runner.run(arguments: ["send-keys", "-t", "=" + name + ":codex", "-l", "Reply with SHARED_TERMINAL_OK. Do not use tools."])
        _ = try await runner.run(arguments: ["send-keys", "-t", "=" + name + ":codex", "Enter"])
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < startDeadline {
            if try await store.journal().contains(where: { $0.kind == "agent.interactive.started" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let interactiveTurn = try #require(await store.journal().last { $0.kind == "agent.interactive.started" }?.detail)
        let forwarded = try await store.addMessage(taskID: task.id, body: "Relevant source update: include FORWARDED_SOURCE_OK in your answer as well.")
        let replyDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < replyDeadline {
            if try await store.outputs(taskID: task.id).contains(where: { $0.text.contains("SHARED_TERMINAL_OK") && $0.kind == "assistant" }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await store.journal().contains { $0.kind == "agent.interactive.started" })
        #expect(try await store.outputs(taskID: task.id).contains { $0.text.contains("SHARED_TERMINAL_OK") && $0.kind == "assistant" })
        #expect(try await store.agentSession(taskID: task.id)?.threadID == workspace.threadID)
        #expect(try await store.messages(taskID: task.id).contains { $0.id == forwarded && $0.delivered })
        #expect(try await store.journal().contains { $0.kind == "agent.steered" && $0.detail.contains(interactiveTurn) })
        let before = try await runner.run(arguments: ["list-windows", "-t", "=" + name, "-F", "#{window_name}|#{window_id}"])
        #expect(try await workspace.prepareTmux() == name)
        let after = try await runner.run(arguments: ["list-windows", "-t", "=" + name, "-F", "#{window_name}|#{window_id}"])
        #expect(before.stdout == after.stdout)
        _ = try await runner.run(arguments: ["kill-window", "-t", "=" + name + ":codex"])
        #expect(try await workspace.prepareTmux() == name)
        let restored = try await runner.run(arguments: ["list-windows", "-t", "=" + name, "-F", "#{window_name}"])
        #expect(String(decoding: restored.stdout, as: UTF8.self).split(separator: "\n").map(String.init) == ["editor", "codex", "shell"])
        _ = try await runner.run(arguments: ["kill-session", "-t", "=" + name])
        loop.cancel(); _ = try? await loop.value; await coordinator.shutdown()
    } catch {
        _ = try? await runner.run(arguments: ["kill-session", "-t", "=" + name])
        loop.cancel(); _ = try? await loop.value; await coordinator.shutdown(); throw error
    }
}
