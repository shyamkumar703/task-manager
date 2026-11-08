import Foundation
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private func managementRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-manager-management-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

@Test func archivingPersistsHidesTaskAndKeepsItsHistory() async throws {
    let root = try managementRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Keep my work", repository: root, kind: .codex)
    try await store.setWorkspace(taskID: task.id, path: root)
    try await store.setThread(taskID: task.id, threadID: "saved-thread")
    _ = try await store.addMessage(taskID: task.id, body: "Retained follow-up")
    try await store.archive(task.id)
    try await store.archive(task.id)
    let reopened = try Store(path: root + "/state.sqlite")
    #expect(try await reopened.tasks().isEmpty)
    #expect(try await reopened.tasks(includeArchived: true).map(\.id) == [task.id])
    #expect(try await reopened.task(task.id).status == .paused)
    #expect(try await reopened.task(task.id).archivedAt != nil)
    #expect(try await reopened.agentSession(taskID: task.id)?.threadID == "saved-thread")
    #expect(try await reopened.outputs(taskID: task.id).contains { $0.text == "Retained follow-up" })
    #expect(try await reopened.journal().filter { $0.kind == "task.archived" }.count == 1)
    try await reopened.restore(task.id)
    #expect(try await reopened.tasks().map(\.id) == [task.id])
    #expect(try await reopened.task(task.id).status == .paused)
}

@Test func archivedTasksCannotBeReactivatedByMessagesApprovalsOrSources() async throws {
    let store = try Store(path: ":memory:")
    let task = try await store.createTask(goal: "Completed", sourceKey: "pr:1")
    try await store.transition(task.id, to: .running)
    let proposal = try await store.proposeComment(taskID: task.id, target: "https://github.com/o/r/pull/1", body: "Draft", expectedHead: "fixture")
    try await store.transition(task.id, to: .completed)
    try await store.archive(task.id)
    #expect(try await store.task(task.id).status == .completed)
    await #expect(throws: ManagerError.self) { try await store.addMessage(taskID: task.id, body: "Wake up") }
    await #expect(throws: ManagerError.self) { try await store.transition(task.id, to: .queued) }
    await #expect(throws: ManagerError.self) { try await store.decide(proposalID: proposal, approve: true) }
    try await store.ingest([SourceEvent(integration: "github", sourceID: "new", revision: "1", associationKey: "pr:1", body: "More feedback", url: "")])
    #expect(try await store.routeKnownEvents() == 0)
    #expect(try await store.pendingEventCount() == 1)
    #expect(try await store.messages(taskID: task.id).isEmpty)
}

@Test func archivedQuestionsStayInHistoryAndRestoreWithoutStarting() async throws {
    let store = try Store(path: ":memory:")
    let task = try await store.createTask(goal: "Question")
    try await store.transition(task.id, to: .running)
    let question = try await store.ask(taskID: task.id, prompt: "Which behavior?")
    try await store.archive(task.id)
    #expect(try await store.questions().isEmpty)
    #expect(try await store.questions(pendingOnly: false).count == 1)
    await #expect(throws: ManagerError.self) { try await store.answer(questionID: question, text: "Answer") }
    try await store.restore(task.id)
    #expect(try await store.questions().map(\.id) == [question])
    #expect(try await store.task(task.id).status == .paused)
}

@Test func coordinatorStopsAnArchivedActiveWorker() async throws {
    let root = try managementRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Archive while running", repository: root, kind: .mock)
    let coordinator = Coordinator(store: store, stateDirectory: root, mockInterval: .milliseconds(50))
    try await coordinator.tick()
    #expect(try await store.agentSession(taskID: task.id)?.workerActive == true)
    try await store.archive(task.id)
    try await coordinator.tick()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while try await store.agentSession(taskID: task.id)?.workerActive == true, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await store.agentSession(taskID: task.id)?.workerActive == false)
    #expect(try await store.tasks().isEmpty)
    #expect(try await store.task(task.id).status == .paused)
    await coordinator.shutdown()
}

@Test func terminalHandoffWaitsForWorkerReleaseAndExcludesAnotherWorker() async throws {
    let root = try managementRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Manual review", repository: root, kind: .codex)
    try await store.setWorkspace(taskID: task.id, path: root)
    try await store.setThread(taskID: task.id, threadID: "persisted-thread")
    #expect(try await store.claimWorker(taskID: task.id))
    try await store.setTurn(taskID: task.id, turnID: "active-turn")
    let preparing = Task { try await ManualTerminal.prepare(store: store, taskID: task.id, timeout: .seconds(2)) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(try await store.task(task.id).status == .paused)
    #expect(try await store.agentSession(taskID: task.id)?.manualActive == true)
    #expect(try await store.agentSession(taskID: task.id)?.workerActive == true)
    try await store.releaseWorker(taskID: task.id)
    let handoff = try await preparing.value
    #expect(handoff.workspace == root)
    #expect(handoff.threadID == "persisted-thread")
    // Even an explicit resume from another UI cannot start a worker in this shell's workspace.
    try await store.resume(task.id)
    #expect(try await store.claimWorker(taskID: task.id) == false)
    await #expect(throws: ManagerError.self) { try await store.claimTerminal(taskID: task.id) }
    let environment = ManualTerminal.environment(for: handoff, inheriting: ["PATH": "/usr/bin"])
    #expect(environment["TASK_MANAGER_TASK_ID"] == task.id)
    #expect(environment["TASK_MANAGER_WORKTREE"] == root)
    #expect(environment["TASK_MANAGER_CODEX_THREAD_ID"] == "persisted-thread")
    try await store.releaseTerminal(taskID: task.id)
    #expect(try await store.claimWorker(taskID: task.id))
    try await store.releaseWorker(taskID: task.id)
}

@Test func failedTerminalHandoffReleasesReservationWithoutResumingWorker() async throws {
    let root = try managementRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let task = try await store.createAgentTask(goal: "Still stopping", repository: root, kind: .codex)
    try await store.setWorkspace(taskID: task.id, path: root)
    #expect(try await store.claimWorker(taskID: task.id))
    await #expect(throws: ManagerError.self) { try await ManualTerminal.prepare(store: store, taskID: task.id, timeout: .milliseconds(50)) }
    #expect(try await store.agentSession(taskID: task.id)?.manualActive == false)
    #expect(try await store.task(task.id).status == .paused)
    try await store.releaseWorker(taskID: task.id)
    let mock = try await store.createAgentTask(goal: "Mock has no shell", repository: root, kind: .mock)
    await #expect(throws: ManagerError.self) { try await ManualTerminal.prepare(store: store, taskID: mock.id) }
}
