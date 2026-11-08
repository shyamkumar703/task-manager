import CodexTransport
import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private func exploreRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("explore-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}
@discardableResult private func exploreGit(_ args: [String]) async throws -> String {
    let result = try await GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git")).run(arguments: args)
    guard result.exitCode == 0 else { throw ManagerError.invalid("Fixture git command failed") }
    return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
private func explorationRepository(_ root: String, branch: String = "main") async throws -> String {
    let repository = root + "/repo"
    try await exploreGit(["init", "-b", branch, repository])
    try Data("Default branch supports list.\n".utf8).write(to: URL(fileURLWithPath: repository + "/README.md"))
    try await exploreGit(["-C", repository, "add", "README.md"])
    try await exploreGit(["-C", repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Default state"])
    return repository
}
private actor ExplorationAgent: AgentConnection {
    nonisolated let events: AsyncStream<CodexClient.Event>
    private let output: AsyncStream<CodexClient.Event>.Continuation
    var start: JSONValue?
    init() { let stream = AsyncStream<CodexClient.Event>.makeStream(); events = stream.stream; output = stream.continuation }
    func connect() {}
    func stop() { output.finish() }
    func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        if method == "thread/start" {
            start = params
            return .object(["thread": .object(["id": .string("exploration-thread")])])
        }
        if method == "turn/start" {
            output.yield(.init(method: "item/completed", params: .object(["threadId": .string("exploration-thread"), "item": .object(["id": .string("reply"), "type": .string("agentMessage"), "text": .string(#"{"status":"completed","text":"README.md:1 verifies list on the inspected snapshot.","reply":"The inspected default branch supports list; feature-only commands are not included."}"#)])])))
            output.yield(.init(method: "turn/completed", params: .object(["threadId": .string("exploration-thread"), "turn": .object(["status": .string("completed")])])))
            return .object(["turn": .object(["id": .string("turn-1")])])
        }
        return .object([:])
    }
}

@Test func explorationInspectsDefaultBranchAndProducesDurableUserActionWithoutResumingFeature() async throws {
    let root = try exploreRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await explorationRepository(root)
    let mainSHA = try await exploreGit(["-C", repository, "rev-parse", "main"])
    try await exploreGit(["-C", repository, "checkout", "-b", "feature-delete"])
    try Data("Feature branch supports list and remove.\n".utf8).write(to: URL(fileURLWithPath: repository + "/README.md"))
    try await exploreGit(["-C", repository, "add", "README.md"])
    try await exploreGit(["-C", repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Feature state"])
    try Data("User scratch".utf8).write(to: URL(fileURLWithPath: repository + "/scratch.txt"))
    let store = try Store(path: root + "/state.sqlite")
    let parent = try await store.createAgentTask(goal: "Implement remove", repository: repository, kind: .codex)
    try await store.transition(parent.id, to: .running)
    try await store.transition(parent.id, to: .completed)
    let eventID = try await store.injectSource(body: "What commands are available right now?", repository: repository)
    _ = try await store.claimTriageEvent()
    let decision = TriageDecision(action: .investigate, taskID: parent.id, goal: "Inspect currently available commands and prepare a reply", reason: "An information request needs a fresh default-branch inspection")
    try await store.applyTriage(eventID: eventID, decision: decision)
    #expect(try await store.applyTriage(eventID: eventID, decision: decision) == false)
    let childID = try #require(await store.source(eventID).taskID)
    #expect(childID != parent.id)
    #expect(try await store.task(parent.id).status == .completed)
    #expect(try await store.messages(taskID: parent.id).isEmpty)
    let agent = ExplorationAgent()
    let coordinator = Coordinator(store: store, stateDirectory: root, factory: { agent })
    try await coordinator.tick()
    for _ in 0..<400 {
        if try await store.task(childID).status == .completed { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await store.task(childID).status == .completed)
    let session = try #require(await store.agentSession(taskID: childID))
    #expect(session.purpose == .exploration)
    #expect(session.baseRef == "refs/heads/main")
    #expect(session.baseSHA == mainSHA)
    let workspace = try #require(session.workspace)
    #expect(try String(contentsOfFile: workspace + "/README.md", encoding: .utf8) == "Default branch supports list.\n")
    #expect(try await exploreGit(["-C", repository, "branch", "--show-current"]) == "feature-delete")
    #expect(try String(contentsOfFile: repository + "/scratch.txt", encoding: .utf8) == "User scratch")
    #expect(await agent.start?["sandbox"]?.string == "read-only")
    let action = try #require(await store.userActions().first)
    #expect(action.sourceEventID == eventID)
    #expect(action.taskID == childID)
    #expect(action.status == "open")
    #expect(action.context.contains(mainSHA))
    #expect(action.body.contains("default branch supports list"))
    let reopened = try Store(path: root + "/state.sqlite")
    #expect(try await reopened.userActions().first?.id == action.id)
    try await reopened.resolveUserAction(action.id)
    #expect(try await reopened.userActions().first?.status == "done")
    await #expect(throws: ManagerError.self) { try await reopened.resolveUserAction(action.id) }
    await coordinator.shutdown()
}

@Test func explorationNeverFallsBackToFeatureHEADWhenDefaultBranchIsUnknown() async throws {
    let root = try exploreRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await explorationRepository(root, branch: "only-feature")
    let workspaces = Workspaces(stateDirectory: root)
    await #expect(throws: ManagerError.self) { try await workspaces.prepareExploration(taskID: UUID().uuidString, repository: repository) }
}

@Test func explorationRecoveryRetainsPinnedCommitWhenDefaultBranchMoves() async throws {
    let root = try exploreRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await explorationRepository(root)
    let workspaces = Workspaces(stateDirectory: root)
    let id = UUID().uuidString
    let first = try await workspaces.prepareExploration(taskID: id, repository: repository)
    try Data("New default state".utf8).write(to: URL(fileURLWithPath: repository + "/README.md"))
    try await exploreGit(["-C", repository, "add", "README.md"])
    try await exploreGit(["-C", repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Moved main"])
    let recovered = try await workspaces.prepareExploration(taskID: id, repository: repository)
    #expect(recovered.sha == first.sha)
    #expect(recovered.sha != (try await exploreGit(["-C", repository, "rev-parse", "main"])))
}

@Test func userCanCorrectAnAlreadyRoutedQuestionWithoutDuplicatingOrChangingFeatureHistory() async throws {
    let root = try exploreRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let parent = try await store.createAgentTask(goal: "Implement remove", repository: root, kind: .mock)
    try await store.transition(parent.id, to: .paused)
    let eventID = try await store.injectSource(body: "What commands exist?", repository: root, workerKind: .mock)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: eventID, decision: .init(action: .route, taskID: parent.id, reason: "Old routing policy"))
    let oldMessage = try #require(await store.messages(taskID: parent.id).first)
    let child = try #require(await store.investigateSource(eventID))
    #expect(child != parent.id)
    #expect(try await store.investigateSource(eventID) == child)
    #expect(try await store.task(parent.id).status == .paused)
    #expect(try await store.messages(taskID: parent.id).first?.id == oldMessage.id)
    #expect(try await store.agentSession(taskID: child)?.purpose == .exploration)
    let coordinator = Coordinator(store: store, stateDirectory: root, mockInterval: .milliseconds(5))
    try await coordinator.tick()
    for _ in 0..<300 {
        if try await store.userActions().count == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await store.userActions().count == 1)
    #expect(try await store.userActions().first?.body.contains("Mock suggested reply") == true)
    #expect(try await store.task(parent.id).status == .paused)
    await coordinator.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_EXPLORATION"] == "1"))
func liveMasterClassifiesCurrentBehaviorQuestionAsIndependentInvestigation() async throws {
    let root = try exploreRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let parent = try await store.createAgentTask(goal: "Implement a remove command in the todo CLI", repository: root, kind: .mock)
    try await store.transition(parent.id, to: .running)
    try await store.transition(parent.id, to: .completed)
    _ = try await store.injectSource(body: "What commands are available in the todo list app right now?", repository: root)
    let event = try #require(await store.claimTriageEvent())
    let candidates = try await store.triageCandidates(repository: root)
    let decision = try await CodexMasterTriage(stateDirectory: root).decide(event: event, candidates: candidates)
    #expect(decision.action == .investigate)
    #expect(decision.goal?.isEmpty == false)
}
