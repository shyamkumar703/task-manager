import Foundation
import TaskManagerCore

extension Store {
    /// Creating the task and reserving its worker record is a single durable operation.
    public func createAgentTask(goal: String, repository: String, kind: WorkerKind) throws -> ManagedTask {
        try requireText(goal, name: "Goal")
        try requireText(repository, name: "Repository")
        let path = URL(fileURLWithPath: repository).standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw ManagerError.invalid("Repository directory does not exist: \(path)")
        }
        return try db.transaction { try insertAgentTask(goal: goal, repository: path, kind: kind) }
    }

    func insertAgentTask(goal: String, repository: String, kind: WorkerKind, purpose: WorkerPurpose = .implementation) throws -> ManagedTask {
        let id = UUID().uuidString
        let now = timestamp()
        try db.execute("INSERT INTO tasks(id, goal, status, source_key, created_at, updated_at) VALUES (?, ?, 'queued', NULL, ?, ?)", [id, goal, now, now])
        try db.execute("INSERT INTO agent_sessions(task_id, repository, kind, purpose) VALUES (?, ?, ?, ?)", [id, repository, kind.rawValue, purpose.rawValue])
        try writeOutput(taskID: id, itemID: "goal", kind: "user", text: goal)
        try log(taskID: id, kind: "task.created", detail: "\(kind.rawValue): \(goal)")
        return try task(id)
    }

    public func agentSession(taskID: String) throws -> AgentSessionRecord? {
        guard let row = try db.query("SELECT * FROM agent_sessions WHERE task_id = ?", [taskID]).first else { return nil }
        var object: [String: Any] = ["taskID": taskID, "repository": row["repository"]!, "kind": row["kind"]!, "purpose": row["purpose"]!, "workerActive": row["worker_active"] == "1", "manualActive": row["manual_active"] == "1"]
        for (column, key) in [("base_ref", "baseRef"), ("base_sha", "baseSHA"), ("workspace", "workspace"), ("thread_id", "threadID"), ("turn_id", "turnID")] {
            if let value = row[column] { object[key] = value }
        }
        return try decode(AgentSessionRecord.self, object)
    }

    public func setWorkspace(taskID: String, path: String) throws {
        try db.transaction {
            guard let session = try agentSession(taskID: taskID) else { throw ManagerError.notFound("No agent session") }
            guard session.workspace == nil || session.workspace == path else { throw ManagerError.conflict("Workspace already assigned") }
            try db.execute("UPDATE agent_sessions SET workspace = ? WHERE task_id = ?", [path, taskID])
            try log(taskID: taskID, kind: "workspace.assigned", detail: path)
        }
    }

    public func setThread(taskID: String, threadID: String) throws {
        try db.transaction {
            try db.execute("UPDATE agent_sessions SET thread_id = ? WHERE task_id = ?", [threadID, taskID])
            guard db.changes == 1 else { throw ManagerError.notFound("No agent session") }
            try log(taskID: taskID, kind: "agent.thread", detail: threadID)
        }
    }

    public func setTurn(taskID: String, turnID: String?) throws {
        try db.execute("UPDATE agent_sessions SET turn_id = ? WHERE task_id = ?", [turnID, taskID])
    }

    /// Transcript items have stable identities. Delta appends and final replacements share a row.
    public func writeOutput(taskID: String, itemID: String, kind: String, text: String, append: Bool = false) throws {
        let update = append ? "substr(agent_output.text || excluded.text, 1, 65536)" : "excluded.text"
        try db.execute("""
            INSERT INTO agent_output(task_id, item_id, kind, text) VALUES (?, ?, ?, ?)
            ON CONFLICT(task_id, item_id) DO UPDATE SET kind = excluded.kind, text = \(update)
            """, [taskID, itemID, kind, String(text.prefix(65536))])
    }

    public func outputs(taskID: String, limit: Int = 200) throws -> [AgentOutput] {
        guard (1...1000).contains(limit) else { throw ManagerError.invalid("Output limit must be 1...1000") }
        return try db.query("SELECT * FROM (SELECT * FROM agent_output WHERE task_id = ? ORDER BY sequence DESC LIMIT ?) ORDER BY sequence", [taskID, String(limit)]).map {
            try decode(AgentOutput.self, ["id": Int64($0["sequence"]!)!, "taskID": $0["task_id"]!, "itemID": $0["item_id"]!, "kind": $0["kind"]!, "text": $0["text"]!])
        }
    }

    public func record(taskID: String?, kind: String, detail: String) throws {
        try log(taskID: taskID, kind: kind, detail: detail)
    }

    /// Cold recovery deliberately pauses work for inspection rather than replaying uncertain tool effects.
    @discardableResult public func recoverAgentSessions() throws -> Int {
        try db.transaction {
            let rows = try db.query("SELECT tasks.id FROM tasks JOIN agent_sessions ON tasks.id = agent_sessions.task_id WHERE tasks.status = 'running'")
            for row in rows {
                let id = row["id"]!
                try changeStatus(id, to: .paused)
                try db.execute("UPDATE agent_sessions SET turn_id = NULL WHERE task_id = ?", [id])
                try log(taskID: id, kind: "agent.recovered", detail: "Paused after coordinator restart; thread, workspace, and inbox preserved")
            }
            try db.execute("UPDATE agent_sessions SET worker_active = 0, turn_id = NULL")
            return rows.count
        }
    }
}
