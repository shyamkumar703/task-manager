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
            try db.execute("UPDATE user_actions SET status = 'dismissed' WHERE source_event_id = ? AND task_id != ? AND status = 'open'", [String(id), child.id])
            try log(taskID: child.id, kind: "source.reinvestigated", detail: "Source \(id); previous target \(event.taskID ?? "none") retained in history")
            return child.id
        }
    }

    public func setExplorationWorkspace(taskID: String, path: String, baseRef: String, baseSHA: String, context: String? = nil) throws {
        try db.transaction {
            guard let session = try agentSession(taskID: taskID), session.purpose == .exploration,
                  session.workspace == nil || (session.workspace == path && session.baseRef == baseRef && session.baseSHA == baseSHA) else { throw ManagerError.conflict("Exploration snapshot cannot be changed") }
            guard try !workspaceReserved(path, excluding: taskID) else { throw ManagerError.conflict("The checkout is reserved by another task") }
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
            let provenance = try output(taskID: taskID, itemID: "inspection-context")?.text ?? "Local inspection; no remote refresh was performed."
            let context = "Inspected \(session.baseRef ?? "mock snapshot") @ \(session.baseSHA ?? "mock").\n\(provenance)\n\n" + findings
            try db.execute("INSERT INTO user_actions(id, task_id, source_event_id, target, body, context) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(task_id, source_event_id) DO UPDATE SET body = excluded.body, context = excluded.context, status = 'open'", [UUID().uuidString, taskID, event["id"]!, event["url"]!, String(reply.prefix(65536)), String(context.prefix(65536))])
            try changeStatus(taskID, to: .completed)
            try log(taskID: taskID, kind: "user_action.ready", detail: "Suggested reply ready for source event \(event["id"]!). Nothing was sent.")
        }
    }
    public func pendingSourceReplies(taskID: String) throws -> [SourceReplyRequest] {
        try db.query("""
            SELECT e.id, e.url, e.body FROM events e JOIN event_context c ON c.event_id = e.id
            WHERE e.task_id = ? AND c.reply_requested = 1 AND e.disposition IN ('routed','created')
              AND NOT EXISTS (SELECT 1 FROM user_actions a WHERE a.task_id = e.task_id AND a.source_event_id = e.id)
            ORDER BY e.id
            """, [taskID]).map { SourceReplyRequest(sourceEventID: Int64($0["id"]!)!, url: $0["url"]!, body: String($0["body"]!.prefix(8192))) }
    }

    /// Finish implementation and prepare source-specific drafts together. Nothing is sent.
    public func completeImplementation(taskID: String, findings: String, sourceReplies: [SourceReply]) throws {
        try db.transaction {
            guard let session = try agentSession(taskID: taskID), session.purpose == .implementation,
                  try task(taskID).status == .running else { throw ManagerError.conflict("Implementation is not running") }
            // A source can arrive after the coordinator's pending-inbox check. Requeue atomically
            // instead of failing because the just-finished turn could not answer that new source.
            if !(try messages(taskID: taskID, pendingOnly: true)).isEmpty {
                try changeStatus(taskID, to: .queued)
                return
            }
            let requests = try pendingSourceReplies(taskID: taskID)
            let requested = Set(requests.map(\.sourceEventID))
            let supplied = Set(sourceReplies.map(\.sourceEventID))
            guard requested == supplied, supplied.count == sourceReplies.count else {
                throw ManagerError.invalid("Implementation must return exactly one sourceReplies draft per pending source; retry to finish the requested response")
            }
            for reply in sourceReplies {
                try requireText(reply.text, name: "Suggested source reply")
                guard reply.text.count <= 65536 else { throw ManagerError.invalid("Suggested source reply is too long") }
                let target = requests.first { $0.sourceEventID == reply.sourceEventID }!
                let context = "Implementation task \(taskID). Worktree: \(session.workspace ?? "not recorded").\n" + String(findings.prefix(60000))
                try db.execute("INSERT INTO user_actions(id, task_id, source_event_id, target, body, context) VALUES (?, ?, ?, ?, ?, ?)", [UUID().uuidString, taskID, String(reply.sourceEventID), target.url, reply.text, context])
                try log(taskID: taskID, kind: "user_action.ready", detail: "Suggested reply ready for source event \(reply.sourceEventID). Nothing was sent.")
            }
            try changeStatus(taskID, to: .completed)
        }
    }

    /// Explicit correction of a finished read-only investigation into existing implementation work.
    public func continueSource(_ eventID: Int64, in taskID: String) throws {
        try db.transaction {
            let event = try source(eventID)
            if event.taskID == taskID && event.disposition == .routed { return }
            guard let oldID = event.taskID, try agentSession(taskID: oldID)?.purpose == .exploration,
                  [.completed, .failed, .paused].contains(try task(oldID).status) else {
                throw ManagerError.conflict("Only a finished or paused investigation can be continued as implementation")
            }
            guard let session = try agentSession(taskID: taskID), session.purpose == .implementation else {
                throw ManagerError.invalid("Choose an existing implementation task")
            }
            // applyTriage performs repository, archive, cancellation, and association checks.
            try db.execute("UPDATE events SET disposition = 'triaging' WHERE id = ?", [String(eventID)])
            let decision = TriageDecision(action: .route, taskID: taskID, reason: "User correction: inspect and fulfill the source requirement in the existing implementation task, then prepare a suggested answer", replyRequested: true)
            try decision.validate()
            _ = try applyValidatedTriage(eventID: eventID, decision: decision)
            guard try source(eventID).disposition == .routed else { return }
            try db.execute("UPDATE user_actions SET status = 'dismissed' WHERE source_event_id = ? AND task_id != ? AND status = 'open'", [String(eventID), taskID])
            try log(taskID: taskID, kind: "source.continued", detail: "Source \(eventID); prior exploration \(oldID) retained in history")
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
