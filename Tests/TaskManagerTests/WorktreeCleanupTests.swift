import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private func cleanupGit(_ args: [String]) async throws -> String {
    let result = try await GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git")).run(arguments: args)
    guard result.exitCode == 0 else { throw ManagerError.invalid("Fixture git failed: \(args)") }
    return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
private struct CleanupFixture {
    let root: String
    let repo: String
    let store: Store
    let task: ManagedTask
    let path: String
    let sha: String
}
private func cleanupFixture() async throws -> CleanupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let repo = root + "/repo"
    try await cleanupGit(["init", "-b", "main", repo])
    try await cleanupGit(["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Initial"])
    let sha = try await cleanupGit(["-C", repo, "rev-parse", "HEAD"])
    try await cleanupGit(["-C", repo, "update-ref", "refs/remotes/origin/main", sha])
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Retire this checkout", repository: repo, kind: .codex)
    let path = try await Workspaces(stateDirectory: root).prepare(taskID: task.id, repository: repo)
    try await store.setWorkspace(taskID: task.id, path: path)
    try await store.setThread(taskID: task.id, threadID: "saved-thread")
    try await store.transition(task.id, to: .running); try await store.transition(task.id, to: .completed)
    return CleanupFixture(root: root, repo: repo, store: store, task: task, path: path, sha: sha)
}

@Test func cleanupRemovesOnlyWorktreeArchivesAndCanRestorePreservedBranch() async throws {
    let f = try await cleanupFixture(); defer { try? FileManager.default.removeItem(atPath: f.root) }
    let plan = try await WorktreeCleanup.preview(store: f.store, taskID: f.task.id, stateDirectory: f.root)
    #expect(plan.blockers.isEmpty)
    #expect(plan.removesFiles)
    #expect(FileManager.default.fileExists(atPath: f.path)) // Preview is read-only.
    try await WorktreeCleanup.execute(plan, store: f.store, stateDirectory: f.root)
    #expect(!FileManager.default.fileExists(atPath: f.path))
    #expect(try await f.store.task(f.task.id).archivedAt != nil)
    #expect(try await f.store.agentSession(taskID: f.task.id)?.workspace == nil)
    #expect(try await f.store.agentSession(taskID: f.task.id)?.threadID == "saved-thread")
    #expect(try await cleanupGit(["-C", f.repo, "rev-parse", "task-manager/" + f.task.id]) == f.sha)
    #expect(try await f.store.journal().contains { $0.kind == "workspace.cleaned" })
    try await f.store.restore(f.task.id)
    let restored = try await Workspaces(stateDirectory: f.root).prepare(taskID: f.task.id, repository: f.repo)
    #expect(try await cleanupGit(["-C", restored, "rev-parse", "HEAD"]) == f.sha)
}

@Test func cleanupRechecksDirtyAndUnpushedWorkWithoutForce() async throws {
    let f = try await cleanupFixture(); defer { try? FileManager.default.removeItem(atPath: f.root) }
    let plan = try await WorktreeCleanup.preview(store: f.store, taskID: f.task.id, stateDirectory: f.root)
    try Data("Important scratch".utf8).write(to: URL(fileURLWithPath: f.path + "/scratch.txt"))
    await #expect(throws: ManagerError.self) { try await WorktreeCleanup.execute(plan, store: f.store, stateDirectory: f.root) }
    #expect(FileManager.default.fileExists(atPath: f.path + "/scratch.txt"))
    #expect(try await f.store.task(f.task.id).archivedAt == nil)
    #expect(try await f.store.agentSession(taskID: f.task.id)?.manualActive == false)
    try await cleanupGit(["-C", f.path, "add", "."])
    try await cleanupGit(["-C", f.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Unpushed work"])
    let unpushed = try await WorktreeCleanup.preview(store: f.store, taskID: f.task.id, stateDirectory: f.root)
    #expect(unpushed.blockers.contains { $0.contains("remote refs") })
    try Data("scratch.txt\n.cache/\n".utf8).write(to: URL(fileURLWithPath: f.path + "/.gitignore"))
    try FileManager.default.createDirectory(atPath: f.path + "/.cache", withIntermediateDirectories: true)
    try Data("ignored data".utf8).write(to: URL(fileURLWithPath: f.path + "/.cache/file"))
    let ignored = try await WorktreeCleanup.preview(store: f.store, taskID: f.task.id, stateDirectory: f.root)
    #expect(ignored.blockers.contains { $0.contains("ignored files") })
}

@Test func cleanupReleasesBorrowedReferencesBeforeRemovingAnOwnedCheckout() async throws {
    let f = try await cleanupFixture(); defer { try? FileManager.default.removeItem(atPath: f.root) }
    let event = try await f.store.injectSource(body: "Explain feature", repository: f.repo, workerKind: .mock)
    _ = try await f.store.claimTriageEvent()
    try await f.store.applyTriage(eventID: event, decision: .init(action: .investigate, taskID: f.task.id, goal: "Explain feature", reason: "Information request"))
    let borrower = try #require(await f.store.source(event).taskID)
    try await f.store.setExplorationWorkspace(taskID: borrower, path: f.path, baseRef: "refs/heads/task-manager/" + f.task.id, baseSHA: f.sha)
    try await f.store.transition(borrower, to: .running); try await f.store.transition(borrower, to: .completed)
    let owned = try await WorktreeCleanup.preview(store: f.store, taskID: f.task.id, stateDirectory: f.root)
    #expect(owned.blockers.contains { $0.contains(borrower) })
    let borrowed = try await WorktreeCleanup.preview(store: f.store, taskID: borrower, stateDirectory: f.root)
    #expect(!borrowed.removesFiles)
    #expect(borrowed.blockers.isEmpty)
    try await WorktreeCleanup.execute(borrowed, store: f.store, stateDirectory: f.root)
    #expect(FileManager.default.fileExists(atPath: f.path))
    #expect(try await f.store.agentSession(taskID: borrower)?.workspace == nil)
    let ready = try await WorktreeCleanup.preview(store: f.store, taskID: f.task.id, stateDirectory: f.root)
    #expect(ready.blockers.isEmpty)
    try await WorktreeCleanup.execute(ready, store: f.store, stateDirectory: f.root)
    #expect(!FileManager.default.fileExists(atPath: f.path))
}

@Test func cleanupReservationBlocksWorkersAndNewSharedCheckoutBindings() async throws {
    let f = try await cleanupFixture(); defer { try? FileManager.default.removeItem(atPath: f.root) }
    try await f.store.reserveWorkspaceCleanup(taskID: f.task.id, workspace: f.path)
    _ = try await f.store.addMessage(taskID: f.task.id, body: "Feedback arriving during cleanup")
    #expect(try await f.store.claimWorker(taskID: f.task.id) == false)
    let other = try await f.store.createAgentTask(goal: "Other", repository: f.repo, kind: .codex)
    await #expect(throws: ManagerError.self) { try await f.store.setWorkspace(taskID: other.id, path: f.path) }
    try await f.store.abortWorkspaceCleanup(taskID: f.task.id, detail: "Test cancellation")
    #expect(try await f.store.agentSession(taskID: f.task.id)?.manualActive == false)
}

@Test func cleanupReconcilesAnAlreadyRemovedWorktreeWithoutDeletingItsBranch() async throws {
    let f = try await cleanupFixture(); defer { try? FileManager.default.removeItem(atPath: f.root) }
    // Simulate a crash after git removal but before metadata finalization.
    try await f.store.reserveWorkspaceCleanup(taskID: f.task.id, workspace: f.path)
    try await cleanupGit(["-C", f.repo, "worktree", "remove", f.path])
    try await f.store.releaseTerminal(taskID: f.task.id)
    let plan = try await WorktreeCleanup.preview(store: f.store, taskID: f.task.id, stateDirectory: f.root)
    #expect(plan.reconcileOnly)
    #expect(!plan.removesFiles)
    #expect(plan.blockers.isEmpty)
    try await WorktreeCleanup.execute(plan, store: f.store, stateDirectory: f.root)
    #expect(try await f.store.agentSession(taskID: f.task.id)?.workspace == nil)
    #expect(try await f.store.task(f.task.id).archivedAt != nil)
    #expect(try await cleanupGit(["-C", f.repo, "rev-parse", "task-manager/" + f.task.id]) == f.sha)
}
