import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence

public enum WorktreeCleanup {
    public struct Plan: Sendable {
        public let taskID: String
        public let workspace: String
        public let branch: String?
        public let head: String?
        public let removesFiles: Bool
        public let reconcileOnly: Bool
        public let blockers: [String]
        public var summary: String {
            (reconcileOnly ? "The worktree is already absent. Clear its saved workspace reference and archive the task:\n" : removesFiles ? "Remove this task's managed worktree:\n" : "Release this task's reference to a borrowed checkout; no files will be removed:\n") + workspace + "\n\nBranch: " + (branch ?? "detached") + "\nCommit: " + (head ?? "unavailable") + "\n\nThe task will be archived. Git branches, conversation, messages, and history are retained. Restore the task explicitly before continuing it."
        }
    }

    private static func git(_ path: String, _ arguments: [String]) async throws -> String? {
        try await GitHubContextResolver.git(path, arguments)
    }

    public static func preview(store: Store, taskID: String, stateDirectory: String) async throws -> Plan {
        let task = try await store.task(taskID)
        guard let session = try await store.agentSession(taskID: taskID), let workspace = session.workspace else {
            throw ManagerError.conflict("This task has no worktree to clean up")
        }
        let expected = URL(fileURLWithPath: stateDirectory).appendingPathComponent("worktrees").appendingPathComponent(taskID).standardizedFileURL.path
        let owned = URL(fileURLWithPath: workspace).standardizedFileURL.path == expected
        let missing = owned && !FileManager.default.fileExists(atPath: workspace)
        var blockers: [String] = []
        if [.running, .queued, .waitingForUser].contains(task.status) { blockers.append("Pause the task first, or wait for its current scope to finish.") }
        if session.workerActive { blockers.append("The child is still stopping. Retry after it pauses.") }
        if session.manualActive { blockers.append("A terminal or cleanup operation owns this task. Close it or release its reservation first.") }
        if await TaskWorkspace.hasTmuxSession(taskID: taskID) != false { blockers.append("Close this task's tmux session before cleanup; its editor or shell may still be using the checkout.") }
        let head = try await git(missing ? session.repository : workspace, ["rev-parse", "--verify", missing ? "refs/heads/task-manager/" + taskID : "HEAD"])
        let branch = missing ? "task-manager/" + taskID : try await git(workspace, ["symbolic-ref", "--short", "-q", "HEAD"])
        if owned && !missing {
            let attributes = try? FileManager.default.attributesOfItem(atPath: workspace)
            if attributes?[.type] as? FileAttributeType != .typeDirectory { blockers.append("The managed worktree is missing or is a symbolic link; no files will be removed.") }
            let common = try await git(workspace, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            let expectedCommon = try await git(session.repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            if common == nil || common != expectedCommon { blockers.append("The worktree does not belong to the recorded repository.") }
            if let status = try await git(workspace, ["status", "--porcelain", "--untracked-files=all", "--ignored"]) {
                if !status.isEmpty { blockers.append("Uncommitted, untracked, or ignored files are present. Commit, move, or remove them first.\n" + String(status.prefix(4000))) }
            } else { blockers.append("Git could not verify that the checkout is clean.") }
            if session.purpose == .implementation {
                if branch != "task-manager/" + taskID { blockers.append("The managed worktree is on a different branch from this task's branch.") }
                let count = try await git(workspace, ["rev-list", "--count", "HEAD", "--not", "--remotes"])
                if count != "0" { blockers.append("Commits are not covered by locally known remote refs. Push your work and update remote refs before cleanup.") }
            } else if let head {
                let refs = try await git(workspace, ["for-each-ref", "--format=%(refname)", "--contains", head, "refs/heads", "refs/remotes"])
                if refs == nil || refs!.isEmpty { blockers.append("The detached inspection commit has no remaining branch reference.") }
            } else { blockers.append("The inspection commit could not be verified.") }
            for other in try await store.tasks(includeArchived: true) where other.id != taskID {
                if let otherSession = try await store.agentSession(taskID: other.id), let path = otherSession.workspace,
                   GitHubContextResolver.canonical(path) == GitHubContextResolver.canonical(workspace) {
                    blockers.append("Task \(other.id) also references this checkout. Clean up that borrowed reference first.")
                }
            }
        }
        return Plan(taskID: taskID, workspace: workspace, branch: branch, head: head, removesFiles: owned && !missing, reconcileOnly: missing, blockers: blockers)
    }

    public static func execute(_ plan: Plan, store: Store, stateDirectory: String) async throws {
        guard plan.blockers.isEmpty else { throw ManagerError.conflict(plan.blockers.joined(separator: "\n")) }
        try await store.reserveWorkspaceCleanup(taskID: plan.taskID, workspace: plan.workspace)
        do {
            // The durable reservation prevents the coordinator from claiming another turn.
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while FileManager.default.fileExists(atPath: TaskWorkspace.file(taskID: plan.taskID, stateDirectory: stateDirectory).path) {
                guard ContinuousClock.now < deadline else { throw ManagerError.conflict("The shared child runtime is still stopping. Retry cleanup after it closes.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            // Recheck disk state after ownership is exclusive and after the confirmation.
            let current = try await previewReserved(plan, store: store, stateDirectory: stateDirectory)
            guard current.head == plan.head, current.branch == plan.branch, current.removesFiles == plan.removesFiles, current.reconcileOnly == plan.reconcileOnly,
                  current.blockers.isEmpty else { throw ManagerError.conflict("Cleanup checks changed. Open cleanup again to review the current checkout.\n" + current.blockers.joined(separator: "\n")) }
            if plan.removesFiles {
                guard let session = try await store.agentSession(taskID: plan.taskID) else { throw ManagerError.notFound("Task session disappeared") }
                let result = try await GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git")).run(arguments: ["-C", session.repository, "worktree", "remove", "--", plan.workspace])
                guard result.exitCode == 0 else { throw ManagerError.conflict("Git declined to remove the worktree. No force removal was attempted; inspect its files before retrying.") }
            }
            try await store.finishWorkspaceCleanup(taskID: plan.taskID, workspace: plan.workspace, removed: plan.removesFiles, reconciled: plan.reconcileOnly)
        } catch {
            try? await store.abortWorkspaceCleanup(taskID: plan.taskID, detail: String(describing: error))
            throw error
        }
    }

    private static func previewReserved(_ plan: Plan, store: Store, stateDirectory: String) async throws -> Plan {
        let current = try await preview(store: store, taskID: plan.taskID, stateDirectory: stateDirectory)
        // Only this operation's reservation is exempt from the second check.
        let blockers = current.blockers.filter { !$0.hasPrefix("A terminal or cleanup operation owns") }
        return Plan(taskID: current.taskID, workspace: current.workspace, branch: current.branch, head: current.head, removesFiles: current.removesFiles, reconcileOnly: current.reconcileOnly, blockers: blockers)
    }
}
