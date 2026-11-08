import Foundation
import TaskManagerCore

extension Store {
    /// Captured once per triage attempt. Context cannot re-ingest messages or authorize mutations.
    func slackRoutingContext(for event: IncomingSource) throws -> SlackRoutingContext? {
        guard event.integration == "slack" else { return nil }
        let parts = event.sourceID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let timestamp = Double(parts[2]), timestamp.isFinite else { return nil }
        let sourceKey = "slack:\(parts[0]):\(parts[1])", prefix = "\(parts[0]):\(parts[1]):"
        guard let channel = try db.query("SELECT * FROM slack_sources WHERE id = ?", [sourceKey]).first else { return nil }
        let thread = String(event.associationKey.split(separator: ":").last ?? parts[2])
        func snippets(threadOnly: Bool, limit: Int) throws -> [SlackMessage] {
            let filter = threadOnly ? " AND thread_timestamp = ?" : ""
            let bindings = [sourceKey, String(parts[2])] + (threadOnly ? [thread] : []) + [String(limit)]
            var messages = try db.query("SELECT * FROM slack_messages WHERE source_key = ? AND CAST(timestamp AS REAL) < CAST(? AS REAL)" + filter + " ORDER BY CAST(timestamp AS REAL) DESC LIMIT ?", bindings).reversed().map {
                SlackMessage(timestamp: $0["timestamp"]!, threadTimestamp: $0["thread_timestamp"]!, author: $0["author"]!, text: String($0["body"]!.prefix(700)))
            }
            if messages.isEmpty {
                // Pre-upgrade baselines already have durable event bodies; use them until the next poll fills the raw cache.
                let threadFilter = threadOnly ? " AND e.association_key = ?" : ""
                let bindings = [prefix + "%", String(prefix.count + 1), String(parts[2])] + (threadOnly ? [event.associationKey] : []) + [String(prefix.count + 1), String(limit)]
                messages = try db.query("SELECT e.* FROM events e WHERE e.integration = 'slack' AND e.source_id LIKE ? AND CAST(substr(e.source_id, ?) AS REAL) < CAST(? AS REAL)" + threadFilter + " AND NOT EXISTS (SELECT 1 FROM events newer WHERE newer.integration = e.integration AND newer.source_id = e.source_id AND newer.id > e.id) ORDER BY CAST(substr(e.source_id, ?) AS REAL) DESC LIMIT ?", bindings).reversed().map {
                    SlackMessage(timestamp: String($0["source_id"]!.dropFirst(prefix.count)), threadTimestamp: String($0["association_key"]!.split(separator: ":").last ?? ""), author: "see message", text: String($0["body"]!.prefix(700)))
                }
            }
            if threadOnly, thread != String(parts[2]), !messages.contains(where: { $0.timestamp == thread }),
               let root = try db.query("SELECT * FROM slack_messages WHERE source_key = ? AND timestamp = ? AND CAST(timestamp AS REAL) < CAST(? AS REAL)", [sourceKey, thread, String(parts[2])]).first {
                messages = [SlackMessage(timestamp: root["timestamp"]!, threadTimestamp: thread, author: root["author"]!, text: String(root["body"]!.prefix(700)))] + Array(messages.suffix(limit - 1))
            }
            return messages
        }
        let evidence = try db.query("""
            SELECT e.source_id, e.body, c.repository, c.reason, c.clarification FROM events e
            JOIN event_context c ON c.event_id = e.id
            WHERE e.integration = 'slack' AND e.source_id LIKE ?
              AND CAST(substr(e.source_id, ?) AS REAL) < CAST(? AS REAL)
              AND e.disposition IN ('routed','created') AND c.repository != ''
            ORDER BY CAST(substr(e.source_id, ?) AS REAL) DESC, e.id DESC LIMIT 4
            """, [prefix + "%", String(prefix.count + 1), String(parts[2]), String(prefix.count + 1)]).map {
                SlackProjectEvidence(repository: $0["repository"]!, sourceID: $0["source_id"]!, message: String($0["body"]!.prefix(700)), reason: String(($0["reason"] ?? "Earlier resolved project").prefix(300)), userClarification: $0["clarification"].map { String($0.prefix(500)) })
            }
        return SlackRoutingContext(workspaceName: channel["workspace_name"]!, channelID: String(parts[1]), channelName: channel["channel_name"]!, topic: channel["channel_topic"].map { String($0.prefix(1000)) }, purpose: channel["channel_purpose"].map { String($0.prefix(1000)) }, precedingMessages: try snippets(threadOnly: false, limit: 8), threadMessages: try snippets(threadOnly: true, limit: 12), projectHistory: evidence)
    }
}
