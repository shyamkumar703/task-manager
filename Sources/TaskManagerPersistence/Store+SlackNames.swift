import Foundation
import TaskManagerCore

extension Store {
    public func slackNames() throws -> SlackNameDirectory {
        let users = try db.query("SELECT workspace_id, user_id, name FROM slack_user_names WHERE name IS NOT NULL").reduce(into: [String: String]()) { $0[$1["workspace_id"]! + ":" + $1["user_id"]!] = $1["name"]! }
        let channels = try db.query("SELECT workspace_id, channel_id, channel_name FROM slack_sources").reduce(into: [String: String]()) { $0[$1["workspace_id"]! + ":" + $1["channel_id"]!] = $1["channel_name"]! }
        return SlackNameDirectory(users: users, channels: channels)
    }
    public func slackNameCandidates(now: Date = Date(), limit: Int = 8) throws -> [(workspaceID: String, userID: String)] {
        let next = try db.query("SELECT workspace_id, user_id, next_lookup FROM slack_user_names").reduce(into: [String: Double]()) { $0[$1["workspace_id"]! + ":" + $1["user_id"]!] = Double($1["next_lookup"]!)! }
        var candidates: [(String, String)] = [], seen = Set<String>()
        func add(_ workspace: String, _ user: String) {
            guard (user.hasPrefix("U") || user.hasPrefix("W")), user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }
            let key = workspace + ":" + user
            if (next[key] ?? 0) <= now.timeIntervalSince1970, seen.insert(key).inserted { candidates.append((workspace, user)) }
        }
        let mentions = try NSRegularExpression(pattern: #"<@([UW][A-Z0-9]+)(?:\|[^>]+)?>"#)
        // Also backfill names on pre-upgrade events, without changing bodies or event revisions.
        for row in try db.query("SELECT source_id, body FROM events WHERE integration = 'slack' ORDER BY id DESC LIMIT 1000") {
            let parts = row["source_id"]!.split(separator: ":")
            guard parts.count == 3 else { continue }
            let workspace = String(parts[0]), body = row["body"]!
            if let first = body.components(separatedBy: "\n").first, first.hasPrefix("Author: ") { add(workspace, String(first.dropFirst(8))) }
            for match in mentions.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let range = Range(match.range(at: 1), in: body) { add(workspace, String(body[range])) }
            }
        }
        for row in try db.query("SELECT s.workspace_id, m.author FROM slack_messages m JOIN slack_sources s ON s.id = m.source_key GROUP BY s.workspace_id, m.author ORDER BY MAX(CAST(m.timestamp AS REAL)) DESC LIMIT 200") {
            add(row["workspace_id"]!, row["author"]!)
        }
        for row in try db.query("SELECT workspace_id, channel_name FROM slack_sources WHERE channel_name LIKE 'DM with %'") {
            add(row["workspace_id"]!, String(row["channel_name"]!.dropFirst(8)))
        }
        return Array(candidates.prefix(max(0, limit)))
    }
    public func cacheSlackUserName(workspaceID: String, user: SlackUserName, now: Date = Date()) throws {
        try requireText(user.name, name: "Slack display name")
        try db.execute("INSERT INTO slack_user_names(workspace_id, user_id, name, next_lookup) VALUES (?, ?, ?, ?) ON CONFLICT(workspace_id, user_id) DO UPDATE SET name = excluded.name, next_lookup = excluded.next_lookup", [workspaceID, user.id, user.name, String(now.addingTimeInterval(86400).timeIntervalSince1970)])
    }
    public func deferSlackUserName(workspaceID: String, userID: String, until: Date) throws {
        // Keep stale names usable when Slack is temporarily unavailable.
        try db.execute("INSERT INTO slack_user_names(workspace_id, user_id, next_lookup) VALUES (?, ?, ?) ON CONFLICT(workspace_id, user_id) DO UPDATE SET next_lookup = excluded.next_lookup", [workspaceID, userID, String(until.timeIntervalSince1970)])
    }
    public func retryMissingSlackNames() throws {
        try db.execute("UPDATE slack_user_names SET next_lookup = 0 WHERE name IS NULL")
    }
}
