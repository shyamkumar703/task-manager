import Foundation
import TaskManagerCore

public actor Store {
    let db: Database

    public init(path: String) throws {
        db = try Database(path: path)
    }

    public func createTask(goal: String, sourceKey: String? = nil) throws -> ManagedTask {
        try requireText(goal, name: "Goal")
        if let sourceKey { try requireText(sourceKey, name: "Source key") }
        return try db.transaction {
            let id = UUID().uuidString
            let now = timestamp()
            try db.execute("INSERT INTO tasks VALUES (?, ?, 'queued', ?, ?, ?)", [id, goal, sourceKey, now, now])
            try log(taskID: id, kind: "task.created", detail: goal)
            return try task(id)
        }
    }

    public func tasks() throws -> [ManagedTask] {
        try db.query("SELECT * FROM tasks ORDER BY created_at, id").map(decodeTask)
    }

    public func task(_ id: String) throws -> ManagedTask {
        guard let row = try db.query("SELECT * FROM tasks WHERE id = ?", [id]).first else {
            throw ManagerError.notFound("Unknown task: \(id)")
        }
        return try decodeTask(row)
    }

    public func transition(_ id: String, to status: TaskStatus) throws {
        try db.transaction { try changeStatus(id, to: status) }
    }

    public func resume(_ id: String) throws {
        try db.transaction {
            guard try task(id).status == .paused else { throw ManagerError.conflict("Only paused tasks can be resumed") }
            let pending = try db.query("SELECT id FROM questions WHERE task_id = ? AND answer IS NULL", [id])
            try changeStatus(id, to: pending.isEmpty ? .queued : .waitingForUser)
        }
    }

    public func addMessage(taskID: String, body: String) throws -> String {
        try requireText(body, name: "Message")
        return try db.transaction {
            let task = try task(taskID)
            guard task.status != .cancelled else { throw ManagerError.conflict("Task is cancelled") }
            let id = try insertMessage(taskID: taskID, body: body)
            if task.status == .completed || task.status == .failed {
                try changeStatus(taskID, to: .queued)
            }
            return id
        }
    }

    public func messages(taskID: String, pendingOnly: Bool = false) throws -> [TaskMessage] {
        _ = try task(taskID)
        let sql = "SELECT * FROM messages WHERE task_id = ?" + (pendingOnly ? " AND delivered = 0" : "") + " ORDER BY sequence"
        return try db.query(sql, [taskID]).map { try decode(TaskMessage.self, [
            "id": $0["id"]!, "taskID": $0["task_id"]!, "body": $0["body"]!, "delivered": $0["delivered"] == "1",
        ]) }
    }

    public func acknowledge(messageID: String) throws {
        try db.transaction {
            guard let message = try db.query("SELECT * FROM messages WHERE id = ?", [messageID]).first else {
                throw ManagerError.notFound("Unknown message: \(messageID)")
            }
            guard message["delivered"] == "0" else { return }
            try db.execute("UPDATE messages SET delivered = 1 WHERE id = ?", [messageID])
            try log(taskID: message["task_id"], kind: "message.delivered", detail: messageID)
        }
    }

    public func ask(taskID: String, prompt: String) throws -> String {
        try requireText(prompt, name: "Question")
        return try db.transaction {
            let id = UUID().uuidString
            try changeStatus(taskID, to: .waitingForUser)
            try db.execute("INSERT INTO questions VALUES (?, ?, ?, NULL)", [id, taskID, prompt])
            try log(taskID: taskID, kind: "question.asked", detail: id)
            return id
        }
    }

    public func questions(pendingOnly: Bool = true) throws -> [Question] {
        try db.query("SELECT questions.* FROM questions JOIN tasks ON tasks.id = questions.task_id" + (pendingOnly ? " WHERE answer IS NULL AND tasks.status != 'cancelled'" : "") + " ORDER BY questions.rowid").map {
            var values: [String: Any] = ["id": $0["id"]!, "taskID": $0["task_id"]!, "prompt": $0["prompt"]!]
            if let answer = $0["answer"] { values["answer"] = answer }
            return try decode(Question.self, values)
        }
    }

    public func answer(questionID: String, text: String) throws {
        try requireText(text, name: "Answer")
        try db.transaction {
            guard let row = try db.query("SELECT * FROM questions WHERE id = ?", [questionID]).first else {
                throw ManagerError.notFound("Unknown question: \(questionID)")
            }
            guard row["answer"] == nil else { throw ManagerError.conflict("Question has already been answered") }
            let taskID = row["task_id"]!
            let current = try task(taskID)
            guard current.status == .waitingForUser || current.status == .paused else {
                throw ManagerError.conflict("Task no longer accepts an answer")
            }
            try db.execute("UPDATE questions SET answer = ? WHERE id = ? AND answer IS NULL", [text, questionID])
            _ = try insertMessage(taskID: taskID, body: "Answer to question \(questionID):\n\(row["prompt"]!)\n\n\(text)")
            if current.status == .waitingForUser { try changeStatus(taskID, to: .queued) }
            try log(taskID: taskID, kind: "question.answered", detail: questionID)
        }
    }

    /// Store an entire fetched page atomically. A future adapter can advance its cursor in this transaction.
    @discardableResult public func ingest(_ events: [SourceEvent]) throws -> Int {
        for event in events {
            for (name, value) in [("integration", event.integration), ("source ID", event.sourceID),
                                  ("revision", event.revision), ("association", event.associationKey), ("body", event.body)] {
                try requireText(value, name: name)
            }
        }
        return try db.transaction {
            var inserted = 0
            for event in events {
                try db.execute("""
                    INSERT INTO events(integration, source_id, revision, association_key, body, url)
                    VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(integration, source_id, revision) DO NOTHING
                    """, [event.integration, event.sourceID, event.revision, event.associationKey, event.body, event.url])
                if db.changes == 1 {
                    inserted += 1
                    try log(taskID: nil, kind: "event.ingested", detail: "\(event.integration):\(event.sourceID):\(event.revision)")
                }
            }
            return inserted
        }
    }

    /// Only established associations route automatically. Unknown events await master triage.
    @discardableResult public func routeKnownEvents() throws -> Int {
        try db.transaction {
            let rows = try db.query("""
                SELECT events.*, tasks.id AS matched_task FROM events
                JOIN tasks ON tasks.source_key = events.association_key
                WHERE events.disposition = 'pending' AND tasks.status != 'cancelled' ORDER BY events.id
                """)
            for row in rows {
                let taskID = row["matched_task"]!
                _ = try insertMessage(taskID: taskID, body: "Source: \(row["url"]!)\n\(row["body"]!)")
                try db.execute("UPDATE events SET disposition = 'routed', task_id = ? WHERE id = ?", [taskID, row["id"]!])
                let status = try task(taskID).status
                if status == .completed || status == .failed { try changeStatus(taskID, to: .queued) }
                try log(taskID: taskID, kind: "event.routed", detail: "\(row["id"]!): established source association")
            }
            return rows.count
        }
    }

    public func pendingEventCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS count FROM events WHERE disposition = 'pending'").first!["count"]!)!
    }

    public func proposeComment(taskID: String, target: String, body: String, expectedHead: String) throws -> String {
        for (name, value) in [("Target", target), ("Body", body), ("Expected head", expectedHead)] {
            try requireText(value, name: name)
        }
        guard let url = URL(string: target), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.pathComponents.count == 5, url.pathComponents[3] == "pull",
              let number = Int(url.pathComponents[4]), number > 0 else {
            throw ManagerError.invalid("Target must be an https://github.com/OWNER/REPO/pull/NUMBER URL")
        }
        return try db.transaction {
            guard try task(taskID).status != .cancelled else { throw ManagerError.conflict("Task is cancelled") }
            let id = UUID().uuidString
            try db.execute("INSERT INTO proposals VALUES (?, ?, 'github.comment', ?, ?, ?, 'pending')", [id, taskID, target, body, expectedHead])
            try log(taskID: taskID, kind: "action.proposed", detail: id)
            return id
        }
    }

    public func proposals() throws -> [ActionProposal] {
        try db.query("SELECT * FROM proposals ORDER BY rowid").map { try decode(ActionProposal.self, [
            "id": $0["id"]!, "taskID": $0["task_id"]!, "kind": $0["kind"]!, "target": $0["target"]!,
            "body": $0["body"]!, "expectedHead": $0["expected_head"]!, "status": $0["status"]!,
        ]) }
    }

    /// Records a decision only. Remote execution is deliberately not implemented yet.
    public func decide(proposalID: String, approve: Bool) throws {
        try db.transaction {
            guard let row = try db.query("SELECT * FROM proposals WHERE id = ?", [proposalID]).first else {
                throw ManagerError.notFound("Unknown proposal: \(proposalID)")
            }
            guard row["status"] == "pending" else { throw ManagerError.conflict("Proposal already decided") }
            guard try task(row["task_id"]!).status != .cancelled else { throw ManagerError.conflict("Task is cancelled") }
            let status = approve ? "approved" : "rejected"
            try db.execute("UPDATE proposals SET status = ? WHERE id = ?", [status, proposalID])
            try log(taskID: row["task_id"], kind: "action.\(status)", detail: proposalID)
        }
    }

    public func journal(after sequence: Int64 = 0) throws -> [JournalEntry] {
        try db.query("SELECT * FROM journal WHERE sequence > ? ORDER BY sequence", [String(sequence)]).map {
            var values: [String: Any] = ["id": Int64($0["sequence"]!)!, "kind": $0["kind"]!, "detail": $0["detail"]!, "createdAt": $0["created_at"]!]
            if let id = $0["task_id"] { values["taskID"] = id }
            return try decode(JournalEntry.self, values)
        }
    }

    func changeStatus(_ id: String, to status: TaskStatus) throws {
        let current = try task(id)
        guard current.status.canTransition(to: status) else {
            throw ManagerError.conflict("Cannot transition \(current.status.rawValue) to \(status.rawValue)")
        }
        if status == .running || status == .queued {
            let pending = try db.query("SELECT id FROM questions WHERE task_id = ? AND answer IS NULL", [id])
            guard pending.isEmpty else { throw ManagerError.conflict("Answer the pending question before starting the task") }
        }
        try db.execute("UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?", [status.rawValue, timestamp(), id])
        try log(taskID: id, kind: "task.status", detail: "\(current.status.rawValue) -> \(status.rawValue)")
    }

    func insertMessage(taskID: String, body: String) throws -> String {
        let id = UUID().uuidString
        try db.execute("INSERT INTO messages(id, task_id, body) VALUES (?, ?, ?)", [id, taskID, body])
        if try agentSession(taskID: taskID) != nil {
            try writeOutput(taskID: taskID, itemID: "message-\(id)", kind: "user", text: body)
        }
        try log(taskID: taskID, kind: "message.received", detail: id)
        return id
    }

    func log(taskID: String?, kind: String, detail: String) throws {
        try db.execute("INSERT INTO journal(task_id, kind, detail, created_at) VALUES (?, ?, ?, ?)", [taskID, kind, detail, timestamp()])
    }

    func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    private func decodeTask(_ row: [String: String]) throws -> ManagedTask {
        var values: [String: Any] = ["id": row["id"]!, "goal": row["goal"]!, "status": row["status"]!, "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!]
        if let source = row["source_key"] { values["sourceKey"] = source }
        return try decode(ManagedTask.self, values)
    }

    func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}
