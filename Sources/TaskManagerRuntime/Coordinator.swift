import CodexTransport
import Foundation
import TaskManagerCore
import TaskManagerPersistence

/// Owns worker lifetimes. The TUI edits durable task state/inboxes; it never owns a worker.
public actor Coordinator {
    private final class Run {
        let generation = UUID().uuidString
        let kind: WorkerKind
        var connection: (any AgentConnection)?
        var job: Task<Void, Never>?
        var listener: Task<Void, Never>?
        var threadID: String?
        var turnID: String?
        var starting = true
        var delivering = false
        var stopping = false
        var completion: JSONValue?
        var result: AgentResult?
        init(kind: WorkerKind) { self.kind = kind }
    }

    private let store: Store
    private let workspaces: Workspaces
    private let factory: @Sendable () -> any AgentConnection
    private let concurrency: Int
    private let mockInterval: Duration
    private var active: [String: Run] = [:]

    public init(store: Store, stateDirectory: String, concurrency: Int = 2, mockInterval: Duration = .seconds(1), factory: @escaping @Sendable () -> any AgentConnection = { CodexConnection() }) {
        self.store = store
        self.workspaces = Workspaces(stateDirectory: stateDirectory)
        self.concurrency = max(1, concurrency)
        self.mockInterval = mockInterval
        self.factory = factory
    }

    public func tick() async throws {
        let tasks = try await store.tasks()
        let statuses = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
        for id in Array(active.keys) {
            guard let run = active[id], !run.stopping else { continue }
            if statuses[id] == .paused || statuses[id] == .cancelled || (statuses[id] == .queued && !run.starting) {
                run.stopping = true
                Task { await self.halt(id, generation: run.generation) }
            } else if run.kind == .codex, !run.starting, !run.delivering, run.turnID != nil {
                run.delivering = true
                Task { await self.deliver(id, generation: run.generation) }
            }
        }
        for task in tasks where task.status == .queued && active[task.id] == nil && active.count < concurrency {
            guard let session = try await store.agentSession(taskID: task.id) else { continue }
            let run = Run(kind: session.kind)
            active[task.id] = run
            run.job = Task { await self.launch(task.id, generation: run.generation) }
        }
    }

    public func shutdown() async {
        for id in Array(active.keys) {
            guard let run = active[id] else { continue }
            if (try? await store.task(id).status) == .running { try? await store.transition(id, to: .paused) }
            run.stopping = true
            await halt(id, generation: run.generation)
        }
    }

    private func launch(_ id: String, generation: String) async {
        guard let run = matching(id, generation) else { return }
        do {
            guard try await store.task(id).status == .queued else { await release(id, generation); return }
            try await store.transition(id, to: .running)
            guard let session = try await store.agentSession(taskID: id) else { throw ManagerError.notFound("No agent session") }
            if session.kind == .mock {
                run.starting = false
                try await runMock(id, generation: generation, session: session)
                return
            }
            try await store.writeOutput(taskID: id, itemID: "setup-\(generation)", kind: "system", text: "Preparing isolated worktree and connecting to Codex…")
            let workspace: String
            if let existing = session.workspace {
                guard FileManager.default.fileExists(atPath: existing) else { throw ManagerError.notFound("Saved worktree is missing: \(existing)") }
                workspace = existing
            } else {
                workspace = try await workspaces.prepare(taskID: id, repository: session.repository)
                try await store.setWorkspace(taskID: id, path: workspace)
            }
            guard matching(id, generation) != nil, try await store.task(id).status == .running else { await release(id, generation); return }
            let connection = factory()
            run.connection = connection
            try await connection.connect()
            guard matching(id, generation) != nil, try await store.task(id).status == .running else { await release(id, generation); return }
            var params: [String: JSONValue] = [
                "cwd": .string(workspace), "sandbox": .string("danger-full-access"), "approvalPolicy": .string("never"),
                "developerInstructions": .string(Self.workerInstructions),
            ]
            let method: String
            if let thread = session.threadID {
                method = "thread/resume"
                params["threadId"] = .string(thread)
                params["excludeTurns"] = .bool(true)
            } else { method = "thread/start" }
            let response = try await connection.request(method, params: .object(params))
            guard matching(id, generation) != nil else { await connection.stop(); return }
            guard let threadID = response["thread"]?["id"]?.string else { throw TransportError.invalidMessage }
            run.threadID = threadID
            try await store.setThread(taskID: id, threadID: threadID)
            guard matching(id, generation) != nil, try await store.task(id).status == .running else { await halt(id, generation: generation); return }
            run.listener = Task {
                for await event in connection.events {
                    await self.receive(id, generation: generation, event: event)
                }
                await self.disconnected(id, generation: generation)
            }
            let task = try await store.task(id)
            let messages = try await store.messages(taskID: id, pendingOnly: true)
            let input = "Task goal: \(task.goal)\n\n" + messages.map { "[message \($0.id)] \($0.body)" }.joined(separator: "\n\n")
            let started = try await connection.request("turn/start", params: .object([
                "threadId": .string(threadID), "input": textInput(input), "outputSchema": AgentResult.schema,
            ]))
            guard let turnID = started["turn"]?["id"]?.string else { throw TransportError.invalidMessage }
            guard matching(id, generation) != nil else { await connection.stop(); return }
            run.turnID = turnID
            try await store.setTurn(taskID: id, turnID: turnID)
            for message in messages { try await store.acknowledge(messageID: message.id) }
            try await store.record(taskID: id, kind: "agent.turn.started", detail: turnID)
            run.starting = false
            await completeIfReady(id, generation)
        } catch {
            await fail(id, generation, error)
        }
    }

    private func deliver(_ id: String, generation: String) async {
        guard let run = matching(id, generation) else { return }
        defer { run.delivering = false }
        do {
            let messages = try await store.messages(taskID: id, pendingOnly: true)
            guard !messages.isEmpty, let connection = run.connection, let thread = run.threadID, let turn = run.turnID,
                  try await store.task(id).status == .running else {
                run.delivering = false
                await completeIfReady(id, generation)
                return
            }
            let text = messages.map { "[message \($0.id)] \($0.body)" }.joined(separator: "\n\n")
            _ = try await connection.request("turn/steer", params: .object([
                "threadId": .string(thread), "expectedTurnId": .string(turn), "input": textInput(text),
            ]))
            for message in messages { try await store.acknowledge(messageID: message.id) }
            try await store.record(taskID: id, kind: "agent.steered", detail: "\(messages.count) message(s) accepted by turn \(turn)")
        } catch {
            // A turn may finish between selecting its ID and sending the update. Keep messages pending.
            try? await store.record(taskID: id, kind: "agent.delivery.deferred", detail: String(describing: error))
        }
        run.delivering = false
        await completeIfReady(id, generation)
    }

    private func receive(_ id: String, generation: String, event: CodexClient.Event) async {
        guard let run = matching(id, generation), !run.stopping else { return }
        let params = event.params
        if let thread = params["threadId"]?.string, thread != run.threadID { return }
        do {
            switch event.method {
            case "item/agentMessage/delta":
                if let item = params["itemId"]?.string, let delta = params["delta"]?.string {
                    try await store.writeOutput(taskID: id, itemID: item, kind: "assistant", text: delta, append: true)
                }
            case "item/started", "item/completed":
                guard let item = params["item"], let itemID = item["id"]?.string else { return }
                if item["type"]?.string == "agentMessage", let text = item["text"]?.string {
                    try await store.writeOutput(taskID: id, itemID: itemID, kind: "assistant", text: text)
                    if let result = try? JSONDecoder().decode(AgentResult.self, from: Data(text.utf8)) { run.result = result }
                } else if item["type"]?.string == "commandExecution" {
                    var text = item["command"]?.string ?? "Running command"
                    if let result = item["aggregatedOutput"]?.string { text += "\n" + String(result.suffix(4000)) }
                    try await store.writeOutput(taskID: id, itemID: itemID, kind: "tool", text: text)
                }
            case "turn/completed":
                run.completion = params["turn"]
                await completeIfReady(id, generation)
            case "client/requestDenied":
                try await store.writeOutput(taskID: id, itemID: UUID().uuidString, kind: "system", text: "Unsupported runtime interaction was declined: \(params["method"]?.string ?? "request")")
            default: break
            }
        } catch { await fail(id, generation, error) }
    }

    private func completeIfReady(_ id: String, _ generation: String) async {
        guard let run = matching(id, generation), !run.starting, !run.delivering, let completion = run.completion else { return }
        run.completion = nil
        do {
            try await store.setTurn(taskID: id, turnID: nil)
            guard try await store.task(id).status == .running else { await release(id, generation); return }
            guard completion["status"]?.string == "completed", let result = run.result,
                  ["question", "completed"].contains(result.status), !result.text.isEmpty else {
                throw ManagerError.invalid(completion["error"]?["message"]?.string ?? "Agent stopped without a valid task outcome. Retry to continue its saved thread.")
            }
            if !(try await store.messages(taskID: id, pendingOnly: true)).isEmpty {
                try await store.transition(id, to: .queued)
            } else if result.status == "question" {
                _ = try await store.ask(taskID: id, prompt: result.text)
            } else { try await store.transition(id, to: .completed) }
            await release(id, generation)
        } catch { await fail(id, generation, error) }
    }

    private func runMock(_ id: String, generation: String, session: AgentSessionRecord) async throws {
        let previous = Int(session.threadID?.split(separator: ":").last ?? "0") ?? 0
        for step in (min(previous, 11) + 1)...12 {
            try await Task.sleep(for: mockInterval)
            guard matching(id, generation) != nil, try await store.task(id).status == .running else { await release(id, generation); return }
            for message in try await store.messages(taskID: id, pendingOnly: true) {
                try await store.writeOutput(taskID: id, itemID: "applied-\(message.id)", kind: "assistant", text: "Mock worker applied follow-up: \(message.body)")
                try await store.acknowledge(messageID: message.id)
                try await store.record(taskID: id, kind: "agent.steered", detail: "Mock accepted message \(message.id)")
            }
            try await store.setThread(taskID: id, threadID: "mock:\(step)")
            try await store.writeOutput(taskID: id, itemID: "mock-step-\(step)", kind: "assistant", text: "Mock step \(step)/12 — working on your task. Send a message to change its instructions.")
            let questions = try await store.questions(pendingOnly: false)
            if step == 4 && !questions.contains(where: { $0.taskID == id }) {
                _ = try await store.ask(taskID: id, prompt: "Mock worker needs your input: which acceptance criterion should I prioritize?")
                await release(id, generation)
                return
            }
        }
        guard let run = matching(id, generation) else { return }
        try await store.writeOutput(taskID: id, itemID: "mock-result-\(generation)", kind: "assistant", text: "Mock task completed. Inbox changes were applied; no files or external systems were changed.")
        run.result = AgentResult(status: "completed", text: "Mock task completed")
        run.completion = .object(["status": .string("completed")])
        await completeIfReady(id, generation)
    }

    private func halt(_ id: String, generation: String) async {
        guard let run = matching(id, generation) else { return }
        run.stopping = true
        if let connection = run.connection, let thread = run.threadID, let turn = run.turnID {
            _ = try? await connection.request("turn/interrupt", params: .object(["threadId": .string(thread), "turnId": .string(turn)]))
        }
        try? await store.setTurn(taskID: id, turnID: nil)
        await release(id, generation)
    }

    private func disconnected(_ id: String, generation: String) async {
        guard let run = matching(id, generation), !run.stopping else { return }
        await fail(id, generation, TransportError.disconnected)
    }

    private func fail(_ id: String, _ generation: String, _ error: any Error) async {
        guard matching(id, generation) != nil else { return }
        if (try? await store.task(id).status) == .running {
            try? await store.writeOutput(taskID: id, itemID: UUID().uuidString, kind: "error", text: String(describing: error))
            try? await store.record(taskID: id, kind: "agent.failed", detail: String(describing: error))
            try? await store.transition(id, to: .failed)
        }
        try? await store.setTurn(taskID: id, turnID: nil)
        await release(id, generation)
    }

    private func release(_ id: String, _ generation: String) async {
        guard let run = matching(id, generation) else { return }
        active.removeValue(forKey: id)
        run.listener?.cancel()
        // Mock jobs can be cancelled safely; a live launch handles its own post-await generation checks.
        if run.kind == .mock { run.job?.cancel() }
        await run.connection?.stop()
    }

    private func matching(_ id: String, _ generation: String) -> Run? {
        guard let run = active[id], run.generation == generation else { return nil }
        return run
    }

    private func textInput(_ text: String) -> JSONValue { .array([.object(["type": .string("text"), "text": .string(text)])]) }

    private static let workerInstructions = """
    You are a child worker of the local task manager. Work toward the task goal in your assigned worktree.
    Incoming messages with stable message IDs are user follow-ups; incorporate them into ongoing work.
    Work locally. Do not push, publish, send messages, comment on GitHub, or mutate any external system.
    Return status=question with a clear question in text when you need user input, then yield.
    Otherwise return status=completed with findings, changed files, verification results, and limitations in text.
    Do not claim success just because a command or turn ended. Never discard unrelated local changes.
    """
}
