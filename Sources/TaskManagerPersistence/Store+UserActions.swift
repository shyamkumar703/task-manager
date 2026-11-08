import Foundation
import TaskManagerCore

extension Store {
    /// Explicit user correction for an already classified source; retain the old inbox and journal.
    @discardableResult public func investigateSource(_ id: Int64) throws -> String? {
        try db.transaction {
            let event = try source(id)
            guard event.disposition != .triaging else { throw ManagerError.conflict("Master is still reviewing this source") }
            if let taskID = event.taskID, try agentSession(taskID: taskID)?.purpose == .exploration { return taskID }
            var repository = event.repository
            if repository.isEmpty, let taskID = event.taskID { repository = try agentSession(taskID: taskID)?.repository ?? "" }
            guard !repository.isEmpty else {
                try db.execute("UPDATE events SET disposition = 'waitingForUser' WHERE id = ?", [String(id)])
                try db.execute("UPDATE event_context SET reason = 'Independent exploration needs a project', question = 'Which local project should be inspected? Enter its absolute checkout path.' WHERE event_id = ?", [String(id)])
                return nil
            }
            let child = try insertAgentTask(goal: "Answer the source question using its PR/branch context and prepare a suggested reply:\n" + String(event.body.prefix(7900)), repository: repository, kind: event.workerKind, purpose: .exploration)
            let context = try event.slackContext ?? slackRoutingContext(for: event)
            let message = try insertMessage(taskID: child.id, body: sourceMessage(integration: event.integration, url: event.url, body: event.body, clarification: event.clarification, context: context))
            try db.execute("UPDATE events SET disposition = 'created', task_id = ? WHERE id = ?", [child.id, String(id)])
            try db.execute("UPDATE event_context SET repository = ?, message_id = ?, reason = 'Independent source-context exploration requested by user', question = NULL, last_error = NULL WHERE event_id = ?", [repository, message, String(id)])
            try log(taskID: child.id, kind: "source.reinvestigated", detail: "Source \(id); previous target \(event.taskID ?? "none") retained in history")
            return child.id
        }
    }

    public func setExplorationWorkspace(taskID: String, path: String, baseRef: String, baseSHA: String, context: String? = nil) throws {
        try db.transaction {
            guard let session = try agentSession(taskID: taskID), session.purpose == .exploration,
                  session.workspace == nil || (session.workspace == path && session.baseRef == baseRef && session.baseSHA == baseSHA) else { throw ManagerError.conflict("Exploration snapshot cannot be changed") }
            try db.execute("UPDATE agent_sessions SET workspace = ?, base_ref = ?, base_sha = ? WHERE task_id = ?", [path, baseRef, baseSHA, taskID])
            try log(taskID: taskID, kind: "exploration.snapshot", detail: "\(baseRef) @ \(baseSHA)")
            if let context {
                try writeOutput(taskID: taskID, itemID: "inspection-context", kind: "system", text: context)
                try log(taskID: taskID, kind: "exploration.context.selected", detail: context)
            }
        }
    }
    public func completeExploration(taskID: String, findings: String, reply: String) throws {
        try requireText(reply, name: "Suggested reply")
        try db.transaction {
            guard let session = try agentSession(taskID: taskID), session.purpose == .exploration,
                  try task(taskID).status == .running else { throw ManagerError.conflict("Exploration is not running") }
            guard let event = try db.query("SELECT id, url FROM events WHERE task_id = ? AND disposition = 'created' ORDER BY id LIMIT 1", [taskID]).first else { throw ManagerError.notFound("Investigation has no source message") }
            let provenance = try outputs(taskID: taskID).first { $0.itemID == "inspection-context" }?.text ?? "Local inspection; no remote refresh was performed."
            let context = "Inspected \(session.baseRef ?? "mock snapshot") @ \(session.baseSHA ?? "mock").\n\(provenance)\n\n" + findings
            try db.execute("INSERT INTO user_actions(id, task_id, source_event_id, target, body, context) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(task_id) DO UPDATE SET body = excluded.body, context = excluded.context, status = 'open'", [UUID().uuidString, taskID, event["id"]!, event["url"]!, String(reply.prefix(65536)), String(context.prefix(65536))])
            try changeStatus(taskID, to: .completed)
            try log(taskID: taskID, kind: "user_action.ready", detail: "Suggested reply ready for source event \(event["id"]!). Nothing was sent.")
        }
    }
    public func userActions() throws -> [UserAction] {
        try db.query("SELECT * FROM user_actions ORDER BY status = 'open' DESC, rowid DESC").map {
            try decode(UserAction.self, ["id": $0["id"]!, "taskID": $0["task_id"]!, "sourceEventID": Int64($0["source_event_id"]!)!, "target": $0["target"]!, "body": $0["body"]!, "context": $0["context"]!, "status": $0["status"]!])
        }
    }
    public func resolveUserAction(_ id: String, dismiss: Bool = false) throws {
        try db.transaction {
            try db.execute("UPDATE user_actions SET status = ? WHERE id = ? AND status = 'open'", [dismiss ? "dismissed" : "done", id])
            guard db.changes == 1 else { throw ManagerError.conflict("This action is no longer open") }
            try log(taskID: nil, kind: "user_action.resolved", detail: "\(id): \(dismiss ? "dismissed" : "done")")
        }
    }
}
