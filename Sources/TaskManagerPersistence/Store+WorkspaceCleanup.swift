import Foundation
import TaskManagerCore

extension Store {
    func workspaceReserved(_ path: String?, excluding taskID: String) throws -> Bool {
        guard let path else { return false }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return try db.query("SELECT workspace FROM agent_sessions WHERE manual_active = 1 AND task_id != ? AND workspace IS NOT NULL", [taskID]).contains {
            URL(fileURLWithPath: $0["workspace"]!).resolvingSymlinksInPath().path == canonical
        }
    }

    public func reserveWorkspaceCleanup(taskID: String, workspace: String) throws {
        try db.transaction {
            let task = try task(taskID)
            guard ![.running, .queued, .waitingForUser].contains(task.status),
                  let session = try agentSession(taskID: taskID), session.workspace == workspace,
                  !session.workerActive, !session.manualActive else { throw ManagerError.conflict("The task became active or its workspace changed. Pause it before cleanup.") }
            guard try !workspaceReserved(workspace, excluding: taskID) else { throw ManagerError.conflict("Another task owns this checkout") }
            try db.execute("UPDATE agent_sessions SET manual_active = 1 WHERE task_id = ?", [taskID])
            try log(taskID: taskID, kind: "workspace.cleanup.requested", detail: workspace)
        }
    }

    public func abortWorkspaceCleanup(taskID: String, detail: String) throws {
        try db.transaction {
            try db.execute("UPDATE agent_sessions SET manual_active = 0 WHERE task_id = ?", [taskID])
            try log(taskID: taskID, kind: "workspace.cleanup.failed", detail: detail)
        }
    }

    public func finishWorkspaceCleanup(taskID: String, workspace: String, removed: Bool, reconciled: Bool = false) throws {
        try db.transaction {
            guard let session = try agentSession(taskID: taskID), session.manualActive, session.workspace == workspace else { throw ManagerError.conflict("Cleanup ownership changed") }
            let current = try task(taskID)
            if [.queued, .running, .waitingForUser].contains(current.status) { try changeStatus(taskID, to: .paused) }
            try db.execute("UPDATE agent_sessions SET workspace = NULL, manual_active = 0, turn_id = NULL, worker_active = 0 WHERE task_id = ?", [taskID])
            try db.execute("UPDATE tasks SET archived_at = ?, updated_at = ? WHERE id = ?", [timestamp(), timestamp(), taskID])
            try log(taskID: taskID, kind: "workspace.cleaned", detail: (reconciled ? "Reconciled an already absent worktree: " : removed ? "Removed managed worktree; branch retained: " : "Released borrowed checkout reference; files retained: ") + workspace)
            try log(taskID: taskID, kind: "task.archived", detail: "Archived by explicit workspace cleanup; conversation and history retained")
        }
    }
}
