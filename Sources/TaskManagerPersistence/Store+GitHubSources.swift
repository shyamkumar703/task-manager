import Foundation
import TaskManagerCore

extension Store {
    @discardableResult public func addGitHubSource(repository: String, localRepository: String, author: String, intervalSeconds: Int = 60) throws -> String {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(allowed.contains) }),
              !author.isEmpty, author.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              (1...86400).contains(intervalSeconds) else { throw ManagerError.invalid("Use OWNER/REPO, a GitHub login, and a poll interval of 1...86400 seconds") }
        let scope = try sourceRepository(localRepository)
        let slug = repository.lowercased()
        return try db.transaction {
            if let existing = try db.query("SELECT id FROM github_sources WHERE repository = ?", [slug]).first {
                throw ManagerError.conflict("Repository is already configured as \(existing["id"]!)")
            }
            let id = UUID().uuidString
            try db.execute("INSERT INTO github_sources(id, repository, local_repository, author, interval_seconds) VALUES (?, ?, ?, ?, ?)", [id, slug, scope, author, String(intervalSeconds)])
            try log(taskID: nil, kind: "github.configured", detail: "\(slug): open PRs authored by \(author), every \(intervalSeconds)s")
            return id
        }
    }

    public func gitHubSources() throws -> [GitHubSource] {
        try db.query("SELECT * FROM github_sources ORDER BY repository").map { row in
            var value: [String: Any] = ["id": row["id"]!, "repository": row["repository"]!, "localRepository": row["local_repository"]!, "author": row["author"]!, "intervalSeconds": Int(row["interval_seconds"]!)!, "enabled": row["enabled"] == "1", "nextPoll": Double(row["next_poll"]!)!, "failures": Int(row["failures"]!)!]
            if let success = row["last_success"] { value["lastSuccess"] = Double(success)! }
            if let error = row["last_error"] { value["lastError"] = error }
            return try decode(GitHubSource.self, value)
        }
    }

    public func setGitHubSourceInterval(_ id: String, seconds: Int) throws {
        guard (1...86400).contains(seconds) else { throw ManagerError.invalid("Interval must be 1...86400 seconds") }
        try db.execute("UPDATE github_sources SET interval_seconds = ?, next_poll = 0 WHERE id = ?", [String(seconds), id])
        guard db.changes == 1 else { throw ManagerError.notFound("Unknown GitHub source") }
    }

    public func setGitHubSourceEnabled(_ id: String, enabled: Bool) throws {
        try db.execute("UPDATE github_sources SET enabled = ?, next_poll = 0 WHERE id = ?", [enabled ? "1" : "0", id])
        guard db.changes == 1 else { throw ManagerError.notFound("Unknown GitHub source") }
    }

    public func finishGitHubPoll(_ id: String, error: String?, retryAfter: Double? = nil, now: Date = Date()) throws {
        try db.transaction {
            guard let source = try gitHubSources().first(where: { $0.id == id }) else { return }
            let failures = error == nil ? 0 : source.failures + 1
            let delay = error == nil ? Double(source.intervalSeconds) : max(Double(source.intervalSeconds), min(3600, pow(2, Double(min(failures, 10))) * 15))
            let next = ceil(max(now.timeIntervalSince1970 + delay, retryAfter ?? 0))
            try db.execute("UPDATE github_sources SET last_success = ?, next_poll = ?, last_error = ?, failures = ? WHERE id = ?", [error == nil ? String(now.timeIntervalSince1970) : source.lastSuccess.map { String($0) }, String(next), error.map { String($0.prefix(2048)) }, String(failures), id])
            try log(taskID: nil, kind: error == nil ? "github.poll.completed" : "github.poll.failed", detail: "\(source.repository): \(error ?? "success")")
        }
    }
}
