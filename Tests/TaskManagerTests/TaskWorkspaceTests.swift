import Foundation
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

@Test func workspaceCommandsUseExactThreadAndPreserveLiteralPaths() {
    let path = "/tmp/project with 'quotes' and $(touch unexpected)"
    let target = TaskWorkspace(taskID: "TASK-ID", threadID: "exact-thread", workspace: path, address: "unix:///tmp/task-agent-test/rpc.sock")
    #expect(target.codexArguments(executable: "/bin/codex") == ["/bin/codex", "resume", "--no-alt-screen", "--remote", "unix:///tmp/task-agent-test/rpc.sock", "--cd", path, "exact-thread"])
    #expect(target.sessionName == "task-task-id")
}

@Test func sharedTurnOwnershipExcludesPausedArchivedAndManualTasks() async throws {
    let store = try Store(path: ":memory:")
    let task = try await store.createAgentTask(goal: "Shared", repository: "/tmp", kind: .codex)
    try await store.setWorkspace(taskID: task.id, path: "/tmp")
    #expect(try await store.claimWorker(taskID: task.id))
    let question = try await store.ask(taskID: task.id, prompt: "Which approach?")
    try await store.releaseWorker(taskID: task.id)
    try await store.observeInteractiveTurn(taskID: task.id, turnID: "terminal-turn")
    #expect(try await store.task(task.id).status == .running)
    #expect(try await store.agentSession(taskID: task.id)?.turnID == "terminal-turn")
    #expect(try await store.questions(pendingOnly: false).first { $0.id == question }?.answer != nil)
    try await store.transition(task.id, to: .paused)
    await #expect(throws: ManagerError.self) { try await store.observeInteractiveTurn(taskID: task.id, turnID: "rejected") }
    _ = try await store.claimTerminal(taskID: task.id)
    try await store.transition(task.id, to: .queued)
    await #expect(throws: ManagerError.self) { try await store.observeInteractiveTurn(taskID: task.id, turnID: "rejected") }
    try await store.releaseTerminal(taskID: task.id)
    try await store.archive(task.id)
    await #expect(throws: ManagerError.self) { try await store.observeInteractiveTurn(taskID: task.id, turnID: "rejected") }
}
