import Foundation
import TaskManagerCore

extension Store {
    public func registerProject(repository: String) throws {
        let path = try sourceRepository(repository)
        try db.execute("INSERT INTO projects(repository) VALUES (?) ON CONFLICT DO NOTHING", [path])
    }
    public func knownRepositories() throws -> [String] {
        let rows = try db.query("SELECT repository FROM projects UNION SELECT repository FROM agent_sessions UNION SELECT local_repository AS repository FROM github_sources UNION SELECT repository FROM slack_sources WHERE repository != ''")
        return Array(Set(rows.compactMap { try? sourceRepository($0["repository"]!) })).sorted()
    }
    public func ensureSlackWorkspace(id: String, name: String, userID: String) throws {
        try db.execute("INSERT INTO slack_workspaces(id, name, user_id) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, user_id = excluded.user_id", [id, name, userID])
    }
    public func slackWorkspaces() throws -> [SlackWorkspace] {
        try db.query("SELECT * FROM slack_workspaces ORDER BY next_discovery, id").map { row in
            var value: [String: Any] = ["id": row["id"]!, "name": row["name"]!, "userID": row["user_id"]!, "nextDiscovery": Double(row["next_discovery"]!)!, "failures": Int(row["failures"]!)!, "pollIntervalSeconds": Int(row["poll_interval_seconds"]!)!]
            if let date = row["last_success"] { value["lastSuccess"] = Double(date)! }
            if let error = row["last_error"] { value["lastError"] = error }
            return try decode(SlackWorkspace.self, value)
        }
    }
    public func setSlackWorkspaceInterval(_ id: String, seconds: Int) throws {
        guard (1...86400).contains(seconds) else { throw ManagerError.invalid("Interval must be 1...86400 seconds") }
        try db.transaction {
            try db.execute("UPDATE slack_workspaces SET poll_interval_seconds = ? WHERE id = ?", [String(seconds), id])
            guard db.changes == 1 else { throw ManagerError.notFound("Unknown Slack workspace") }
            try db.execute("UPDATE slack_sources SET interval_seconds = ?, next_poll = 0 WHERE workspace_id = ?", [String(seconds), id])
            try log(taskID: nil, kind: "slack.interval.updated", detail: "\(id): all current and future conversations default to \(seconds)s")
        }
    }
    public func reconcileSlackConversations(workspaceID: String, conversations: [SlackConversation], now: Date = Date()) throws {
        try db.transaction {
            guard let workspace = try slackWorkspaces().first(where: { $0.id == workspaceID }) else { throw ManagerError.notFound("Unknown Slack workspace") }
            for conversation in conversations {
                let id = "slack:\(workspaceID):\(conversation.id)"
                // Existing pauses, bindings, checkpoints and intervals remain under user control.
                try db.execute("INSERT INTO slack_sources(id, workspace_id, workspace_name, user_id, channel_id, channel_name, channel_topic, channel_purpose, repository, interval_seconds) VALUES (?, ?, ?, ?, ?, ?, ?, ?, '', ?) ON CONFLICT(id) DO UPDATE SET channel_name = excluded.channel_name, workspace_name = excluded.workspace_name, channel_topic = excluded.channel_topic, channel_purpose = excluded.channel_purpose", [id, workspaceID, workspace.name, workspace.userID, conversation.id, conversation.name, conversation.topic, conversation.purpose, String(workspace.intervalSeconds)])
            }
            let staleQuestions = try db.query("SELECT e.id FROM events e JOIN event_context c ON c.event_id = e.id WHERE e.integration = 'slack' AND e.source_id LIKE ? AND e.disposition = 'waitingForUser' AND c.repository = '' AND c.routing_context IS NULL AND (lower(c.question) LIKE '%which%project%' OR lower(c.question) LIKE '%which%repository%' OR lower(c.question) LIKE '%what%project%')", [workspaceID + ":%"])
            for row in staleQuestions {
                try db.execute("UPDATE events SET disposition = 'pending' WHERE id = ?", [row["id"]!])
                try db.execute("UPDATE event_context SET question = NULL, reason = 'Reconsidering project using Slack conversation context', attempts = 0, retry_after = 0, last_error = NULL WHERE event_id = ?", [row["id"]!])
                try log(taskID: nil, kind: "triage.context_refreshed", detail: row["id"]!)
            }
            try db.execute("UPDATE slack_workspaces SET next_discovery = ?, last_success = ?, last_error = NULL, failures = 0 WHERE id = ?", [String(ceil(now.timeIntervalSince1970 + 60)), String(now.timeIntervalSince1970), workspaceID])
            try log(taskID: nil, kind: "slack.discovered", detail: "\(workspaceID): monitoring \(conversations.count) discovered conversations")
        }
    }
    public func retrySlackDiscovery(_ id: String) throws {
        try db.execute("UPDATE slack_workspaces SET next_discovery = 0 WHERE id = ?", [id])
        guard db.changes == 1 else { throw ManagerError.notFound("Unknown Slack workspace") }
    }
    public func failSlackDiscovery(_ id: String, error: String, retryAfter: Double? = nil, now: Date = Date()) throws {
        try db.transaction {
            guard let workspace = try slackWorkspaces().first(where: { $0.id == id }) else { return }
            let failures = workspace.failures + 1
            let delay = min(3600, pow(2, Double(min(failures, 10))) * 30)
            let next = ceil(max(now.timeIntervalSince1970 + delay, retryAfter ?? 0))
            try db.execute("UPDATE slack_workspaces SET next_discovery = ?, last_error = ?, failures = ? WHERE id = ?", [String(next), String(error.prefix(2048)), String(failures), id])
            if let retryAfter { try db.execute("UPDATE slack_sources SET next_poll = MAX(next_poll, ?) WHERE workspace_id = ?", [String(ceil(retryAfter)), id]) }
            try log(taskID: nil, kind: "slack.discovery.failed", detail: "\(id): \(error)")
        }
    }
}
