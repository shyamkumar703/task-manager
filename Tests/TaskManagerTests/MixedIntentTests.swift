import CodexTransport
import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private let groupingMessage = "we should be using `todo folders add Work` or something similar in order to create lists of todos that are grouped. are we doing that now?"

private func mixedRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-intent-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

private actor MixedWorker: AgentConnection {
    nonisolated let events: AsyncStream<CodexClient.Event>
    let continuation: AsyncStream<CodexClient.Event>.Continuation
    let replies: [SourceReply]
    var methods: [String] = []
    var input: String?
    init(replies: [SourceReply]) {
        self.replies = replies
        let pair = AsyncStream<CodexClient.Event>.makeStream(); events = pair.stream; continuation = pair.continuation
    }
    func connect() {}
    func stop() { continuation.finish() }
    func request(_ method: String, params: JSONValue) throws -> JSONValue {
        methods.append(method)
        if method == "thread/resume" {
            #expect(params["threadId"]?.string == "grouping-thread")
            return .object(["thread": .object(["id": .string("grouping-thread")])])
        }
        if method == "turn/start" {
            if case .array(let items) = params["input"] { input = items.first?["text"]?.string }
            let payload: [String: Any] = ["status": "completed", "text": "Inspected the existing grouping implementation and verified the supported syntax.", "reply": NSNull(), "sourceReplies": replies.map { ["sourceEventID": $0.sourceEventID, "text": $0.text] as [String: Any] }]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            continuation.yield(.init(method: "item/completed", params: .object(["threadId": .string("grouping-thread"), "item": .object(["id": .string("result"), "type": .string("agentMessage"), "text": .string(text)])])))
            continuation.yield(.init(method: "turn/completed", params: .object(["threadId": .string("grouping-thread"), "turn": .object(["id": .string("turn"), "status": .string("completed")])])))
            return .object(["turn": .object(["id": .string("turn")])])
        }
        return .object([:])
    }
}

@Test func mixedFollowupsResumeOneImplementationAndPrepareSeparateSourceReplies() async throws {
    let root = try mixedRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git"))
    for args in [["init", "-b", "main", root], ["-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Initial"]] {
        #expect(try await runner.run(arguments: args).exitCode == 0)
    }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Group todos into folders", repository: root, kind: .codex)
    let workspace = try await Workspaces(stateDirectory: root).prepare(taskID: task.id, repository: root)
    try await store.setWorkspace(taskID: task.id, path: workspace)
    try await store.setThread(taskID: task.id, threadID: "grouping-thread")
    try await store.transition(task.id, to: .running); try await store.transition(task.id, to: .completed)
    let first = try await store.injectSource(body: groupingMessage, repository: root, associationKey: "thread-one")
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: first, decision: .init(action: .route, taskID: task.id, reason: "Requirement plus question refines the grouping implementation", replyRequested: true))
    let second = try await store.injectSource(body: "Make the folder name optional when listing; can you confirm the behavior?", repository: root, associationKey: "thread-two")
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: second, decision: .init(action: .route, taskID: task.id, reason: "Compatible follow-up with a requested answer", replyRequested: true))
    let worker = MixedWorker(replies: [.init(sourceEventID: first, text: "Folders group todos; use the equivalent folder creation command."), .init(sourceEventID: second, text: "Folder filtering is optional when listing.")])
    let coordinator = Coordinator(store: store, stateDirectory: root, factory: { worker })
    try await coordinator.tick()
    for _ in 0..<300 {
        if try await store.task(task.id).status != .running { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await store.task(task.id).status == .completed)
    #expect(try await store.tasks().count == 1)
    #expect(try await store.agentSession(taskID: task.id)?.workspace == workspace)
    #expect(await worker.methods.contains("thread/resume"))
    #expect(await worker.input?.contains("Pending source replies") == true)
    #expect(await worker.input?.contains(groupingMessage) == true)
    let actions = try await store.userActions()
    #expect(actions.count == 2)
    #expect(Set(actions.map(\.sourceEventID)) == [first, second])
    #expect(Set(actions.map(\.target)).count == 2)
    #expect(actions.allSatisfy { $0.taskID == task.id && $0.status == "open" })
    #expect(try await store.pendingSourceReplies(taskID: task.id).isEmpty)
    await coordinator.shutdown()
}

@Test func sourceReplyValidationIsAtomicAndOldRepliesSurviveLaterFollowups() async throws {
    let root = try mixedRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Grouping", repository: root, kind: .mock)
    let first = try await store.injectSource(body: groupingMessage, repository: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: first, decision: .init(action: .route, taskID: task.id, reason: "Mixed intent", replyRequested: true))
    for message in try await store.messages(taskID: task.id, pendingOnly: true) { try await store.acknowledge(messageID: message.id) }
    try await store.transition(task.id, to: .running)
    await #expect(throws: ManagerError.self) { try await store.completeImplementation(taskID: task.id, findings: "Done", sourceReplies: []) }
    await #expect(throws: ManagerError.self) { try await store.completeImplementation(taskID: task.id, findings: "Done", sourceReplies: [.init(sourceEventID: first, text: "Good"), .init(sourceEventID: first + 999, text: "Forged")]) }
    #expect(try await store.userActions().isEmpty)
    #expect(try await store.task(task.id).status == .running)
    try await store.completeImplementation(taskID: task.id, findings: "Verified", sourceReplies: [.init(sourceEventID: first, text: "First answer")])
    let action = try #require(await store.userActions().first)
    try await store.resolveUserAction(action.id)
    let second = try await store.injectSource(body: "Also support Personal; does that work?", repository: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: second, decision: .init(action: .route, taskID: task.id, reason: "Next requirement", replyRequested: true))
    for message in try await store.messages(taskID: task.id, pendingOnly: true) { try await store.acknowledge(messageID: message.id) }
    try await store.transition(task.id, to: .running)
    try await store.completeImplementation(taskID: task.id, findings: "Verified second", sourceReplies: [.init(sourceEventID: second, text: "Second answer")])
    let reopened = try Store(path: root + "/state.sqlite")
    let actions = try await reopened.userActions()
    #expect(actions.count == 2)
    #expect(actions.first { $0.id == action.id }?.status == "done")
    #expect(actions.first { $0.sourceEventID == first }?.body == "First answer")
    #expect(actions.first { $0.sourceEventID == second }?.body == "Second answer")
}

@Test func implementationCompletionDefersWhenANewSourceHasNotReachedTheWorker() async throws {
    let root = try mixedRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let task = try await store.createAgentTask(goal: "Grouping", repository: root, kind: .mock)
    try await store.transition(task.id, to: .running)
    let event = try await store.injectSource(body: groupingMessage, repository: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: event, decision: .init(action: .route, taskID: task.id, reason: "Follow-up arrived as the turn finished", replyRequested: true))
    try await store.completeImplementation(taskID: task.id, findings: "Earlier scope finished", sourceReplies: [])
    #expect(try await store.task(task.id).status == .queued)
    #expect(try await store.userActions().isEmpty)
    #expect(try await store.pendingSourceReplies(taskID: task.id).count == 1)
}

@Test func finishedExplorationCanBeCorrectedIntoExistingWorkWithoutLosingHistory() async throws {
    let root = try mixedRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let parent = try await store.createAgentTask(goal: "Group todos", repository: root, kind: .mock)
    try await store.transition(parent.id, to: .running); try await store.transition(parent.id, to: .completed)
    let event = try await store.injectSource(body: groupingMessage, repository: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: event, decision: .init(action: .investigate, taskID: parent.id, goal: "Check grouping", reason: "Old classification"))
    let explorer = try #require(await store.source(event).taskID)
    try await store.transition(explorer, to: .running)
    try await store.completeExploration(taskID: explorer, findings: "Old investigation", reply: "Old read-only answer")
    try await store.continueSource(event, in: parent.id)
    try await store.continueSource(event, in: parent.id)
    #expect(try await store.source(event).taskID == parent.id)
    #expect(try await store.task(parent.id).status == .queued)
    #expect(try await store.messages(taskID: parent.id).count == 1)
    #expect(try await store.messages(taskID: explorer).count == 1)
    #expect(try await store.task(explorer).status == .completed)
    #expect(try await store.userActions().first?.status == "dismissed")
    #expect(try await store.pendingSourceReplies(taskID: parent.id).map(\.sourceEventID) == [event])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_MIXED_INTENT"] == "1"))
func liveMasterDistinguishesMixedGroupingRequirementFromPureQuestion() async throws {
    let root = try mixedRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let task = try await store.createAgentTask(goal: "Group todos into folder-like structures", repository: root, kind: .mock)
    try await store.transition(task.id, to: .running); try await store.transition(task.id, to: .completed)
    try await store.writeOutput(taskID: task.id, itemID: "last-result", kind: "assistant", text: "Implemented folder grouping with todo folders create NAME and todo list --folder NAME. Local worktree retained for follow-ups.")
    let master = CodexMasterTriage(stateDirectory: root)
    let mixedID = try await store.injectSource(body: groupingMessage, repository: root)
    let mixed = try await master.decide(event: store.source(mixedID), candidates: store.triageCandidates(repository: root))
    #expect(mixed.action == .route)
    #expect(mixed.taskID == task.id)
    #expect(mixed.replyRequested == true)
    let pureID = try await store.injectSource(body: "What commands are available for folders right now?", repository: root)
    let pure = try await master.decide(event: store.source(pureID), candidates: store.triageCandidates(repository: root))
    #expect(pure.action == .investigate)
    let newWork = try await master.decide(event: store.source(mixedID), candidates: [])
    #expect(newWork.action == .create)
    #expect(newWork.replyRequested == true)
}
