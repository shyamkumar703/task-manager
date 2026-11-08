import Foundation
import TaskManagerCore

extension Store {
    @discardableResult public func addSlackSource(workspaceID: String, workspaceName: String, userID: String, channelID: String, channelName: String, repository: String = "", intervalSeconds: Int = 60) throws -> String {
        for value in [workspaceID, userID, channelID] {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw ManagerError.invalid("Invalid Slack workspace, user or conversation ID") }
        }
        try requireText(workspaceName, name: "Workspace name")
        try requireText(channelName, name: "Conversation name")
        guard (10...86400).contains(intervalSeconds) else { throw ManagerError.invalid("Interval must be 10...86400 seconds") }
        let scope = repository.isEmpty ? "" : try sourceRepository(repository)
        let id = "slack:\(workspaceID):\(channelID)"
        return try db.transaction {
            guard try db.query("SELECT id FROM slack_sources WHERE id = ?", [id]).isEmpty else { throw ManagerError.conflict("Slack conversation is already configured") }
            try db.execute("INSERT INTO slack_sources(id, workspace_id, workspace_name, user_id, channel_id, channel_name, repository, interval_seconds) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [id, workspaceID, workspaceName, userID, channelID, channelName, scope, String(intervalSeconds)])
            try log(taskID: nil, kind: "slack.configured", detail: "\(id): \(channelName) → \(scope)")
            return id
        }
    }
    public func slackSources() throws -> [SlackSource] {
        try db.query("SELECT * FROM slack_sources ORDER BY next_poll, id").map { row in
            var value: [String: Any] = ["id": row["id"]!, "workspaceID": row["workspace_id"]!, "workspaceName": row["workspace_name"]!, "userID": row["user_id"]!, "channelID": row["channel_id"]!, "channelName": row["channel_name"]!, "repository": row["repository"]!, "intervalSeconds": Int(row["interval_seconds"]!)!, "enabled": row["enabled"] == "1", "nextPoll": Double(row["next_poll"]!)!, "failures": Int(row["failures"]!)!]
            if let date = row["last_success"] { value["lastSuccess"] = Double(date)! }
            if let error = row["last_error"] { value["lastError"] = error }
            return try decode(SlackSource.self, value)
        }
    }
    public func setSlackSourceEnabled(_ id: String, enabled: Bool) throws {
        try db.execute("UPDATE slack_sources SET enabled = ?, next_poll = 0 WHERE id = ?", [enabled ? "1" : "0", id])
        guard db.changes == 1 else { throw ManagerError.notFound("Unknown Slack source") }
    }
    public func setSlackSourceInterval(_ id: String, seconds: Int) throws {
        guard (10...86400).contains(seconds) else { throw ManagerError.invalid("Interval must be 10...86400 seconds") }
        try db.execute("UPDATE slack_sources SET interval_seconds = ?, next_poll = 0 WHERE id = ?", [String(seconds), id])
        guard db.changes == 1 else { throw ManagerError.notFound("Unknown Slack source") }
    }
    /// Commit the complete snapshot, event revisions, checkpoint and schedule together.
    @discardableResult public func commitSlackPoll(_ id: String, expectedGeneration: Int?, events: [SourceEvent], now: Date = Date()) throws -> Int {
        for event in events {
            for value in [event.sourceID, event.revision, event.body, event.associationKey] { try requireText(value, name: "Slack event field") }
        }
        return try db.transaction {
            guard let source = try slackSources().first(where: { $0.id == id }), source.enabled else { throw ManagerError.conflict("Slack source is disabled or unavailable") }
            guard events.allSatisfy({ $0.integration == "slack" && $0.sourceID.hasPrefix("\(source.workspaceID):\(source.channelID):") && $0.associationKey.hasPrefix("\(id):thread:") }) else { throw ManagerError.conflict("Slack batch belongs to another conversation") }
            let cursor = try pollingCursor(sourceKey: id, repository: source.repository, workerKind: .codex)
            guard cursor?.generation == expectedGeneration else { throw ManagerError.conflict("Slack cursor changed; fetch again") }
            let inserted = try ingestBatch(events, scope: source.repository, workerKind: .codex, baseline: cursor == nil)
            try db.execute("INSERT INTO polling_cursors(source_key, repository, worker_kind, generation, completed_at) VALUES (?, ?, 'codex', ?, ?) ON CONFLICT(source_key) DO UPDATE SET generation = excluded.generation, completed_at = excluded.completed_at", [id, source.repository, String((expectedGeneration ?? 0) + 1), ISO8601DateFormatter().string(from: now)])
            try db.execute("UPDATE slack_sources SET last_success = ?, next_poll = ?, last_error = NULL, failures = 0 WHERE id = ?", [String(now.timeIntervalSince1970), String(ceil(now.timeIntervalSince1970 + Double(source.intervalSeconds))), id])
            try log(taskID: nil, kind: cursor == nil ? "slack.baselined" : "slack.polled", detail: "\(id): \(inserted) new revisions")
            return inserted
        }
    }
    public func failSlackPoll(_ id: String, error: String, retryAfter: Double? = nil, now: Date = Date()) throws {
        try db.transaction {
            guard let source = try slackSources().first(where: { $0.id == id }) else { return }
            let failures = source.failures + 1
            let delay = max(Double(source.intervalSeconds), min(3600, pow(2, Double(min(failures, 10))) * 15))
            let next = ceil(max(now.timeIntervalSince1970 + delay, retryAfter ?? 0))
            try db.execute("UPDATE slack_sources SET next_poll = ?, last_error = ?, failures = ? WHERE id = ?", [String(next), String(error.prefix(2048)), String(failures), id])
            if let retryAfter {
                try db.execute("UPDATE slack_sources SET next_poll = MAX(next_poll, ?) WHERE workspace_id = ?", [String(ceil(retryAfter)), source.workspaceID])
                try db.execute("UPDATE slack_workspaces SET next_discovery = MAX(next_discovery, ?) WHERE id = ?", [String(ceil(retryAfter)), source.workspaceID])
            }
            try log(taskID: nil, kind: "slack.poll.failed", detail: "\(id): \(error)")
        }
    }
}
