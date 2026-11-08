import Foundation
import TaskManagerCore

public struct PollingCursor: Codable, Sendable {
    public let generation: Int
    public let completedAt: String
}

extension Store {
    public func pollingCursor(sourceKey: String, repository: String, workerKind: WorkerKind) throws -> PollingCursor? {
        let scope = try sourceRepository(repository)
        guard let row = try db.query("SELECT * FROM polling_cursors WHERE source_key = ?", [sourceKey]).first else { return nil }
        guard row["repository"] == scope, row["worker_kind"] == workerKind.rawValue else {
            throw ManagerError.conflict("Polling source is already configured for a different repository or worker kind")
        }
        return PollingCursor(generation: Int(row["generation"]!)!, completedAt: row["completed_at"]!)
    }

    /// Commit only a complete fetched snapshot. First contact records history without scheduling work.
    /// Revision uniqueness is the event watermark; generation prevents stale concurrent poll commits.
    @discardableResult public func commitPoll(sourceKey: String, repository: String, workerKind: WorkerKind,
                                             expectedGeneration: Int?, events: [SourceEvent]) throws -> Int {
        try requireText(sourceKey, name: "Polling source key")
        let scope = try sourceRepository(repository)
        for event in events {
            for value in [event.integration, event.sourceID, event.revision, event.associationKey, event.body] {
                try requireText(value, name: "Source event field")
            }
        }
        return try db.transaction {
            let cursor = try pollingCursor(sourceKey: sourceKey, repository: scope, workerKind: workerKind)
            guard cursor?.generation == expectedGeneration else { throw ManagerError.conflict("Polling cursor changed; fetch again before committing") }
            let inserted = try ingestBatch(events, scope: scope, workerKind: workerKind, baseline: cursor == nil)
            try db.execute("INSERT INTO polling_cursors(source_key, repository, worker_kind, generation, completed_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(source_key) DO UPDATE SET generation = excluded.generation, completed_at = excluded.completed_at",
                           [sourceKey, scope, workerKind.rawValue, String((expectedGeneration ?? 0) + 1), ISO8601DateFormatter().string(from: Date())])
            try log(taskID: nil, kind: cursor == nil ? "source.baselined" : "source.polled", detail: "\(sourceKey): \(inserted) new revisions")
            return inserted
        }
    }
}
