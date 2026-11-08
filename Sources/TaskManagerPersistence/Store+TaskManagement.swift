import Foundation
import TaskManagerCore

extension Store {
    /// Hide a task without destroying its worktree, transcript, or source history.
    public func archive(_ id: String) throws {
        try db.transaction {
            let current = try task(id)
            guard current.archivedAt == nil else { return }
            if [.queued, .running, .waitingForUser].contains(current.status) { try changeStatus(id, to: .paused) }
            try db.execute("UPDATE tasks SET archived_at = ?, updated_at = ? WHERE id = ?", [timestamp(), timestamp(), id])
            try log(taskID: id, kind: "task.archived", detail: "Removed from task list; history and local work retained")
        }
    }

    public func restore(_ id: String) throws {
        try db.transaction {
            guard try task(id).archivedAt != nil else { return }
            try db.execute("UPDATE tasks SET archived_at = NULL, updated_at = ? WHERE id = ?", [timestamp(), id])
            try log(taskID: id, kind: "task.restored", detail: "Returned to task list without starting a worker")
        }
    }

    /// Atomically reserve execution, including the status change. Manual shells exclude workers.
    public func claimWorker(taskID: String) throws -> Bool {
        try db.transaction {
            let current = try task(taskID)
            guard current.archivedAt == nil, current.status == .queued,
                  let session = try agentSession(taskID: taskID), !session.workerActive, !session.manualActive else { return false }
            try changeStatus(taskID, to: .running)
            try db.execute("UPDATE agent_sessions SET worker_active = 1 WHERE task_id = ?", [taskID])
            return true
        }
    }

    public func releaseWorker(taskID: String) throws {
        try db.execute("UPDATE agent_sessions SET worker_active = 0, turn_id = NULL WHERE task_id = ?", [taskID])
    }

    /// Reserve manual control before asking the worker to yield, closing the resume/claim race.
    public func claimTerminal(taskID: String) throws -> AgentSessionRecord {
        try db.transaction {
            let current = try task(taskID)
            guard current.archivedAt == nil else { throw ManagerError.conflict("Task is archived; restore it first") }
            guard let session = try agentSession(taskID: taskID), session.kind == .codex, session.workspace != nil else {
                throw ManagerError.conflict("This task has no worktree yet. Mock tasks do not create worktrees.")
            }
            guard !session.manualActive else { throw ManagerError.conflict("A terminal already owns this task. Close it first, or use release-terminal after a crashed terminal.") }
            if [.queued, .running].contains(current.status) { try changeStatus(taskID, to: .paused) }
            try db.execute("UPDATE agent_sessions SET manual_active = 1 WHERE task_id = ?", [taskID])
            try log(taskID: taskID, kind: "terminal.requested", detail: session.workspace!)
            return try agentSession(taskID: taskID)!
        }
    }

    public func releaseTerminal(taskID: String) throws {
        try db.transaction {
            _ = try task(taskID)
            try db.execute("UPDATE agent_sessions SET manual_active = 0 WHERE task_id = ? AND manual_active = 1", [taskID])
            if db.changes == 1 { try log(taskID: taskID, kind: "terminal.closed", detail: "Manual workspace ownership released") }
        }
    }
}
