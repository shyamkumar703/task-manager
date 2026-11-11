import Foundation
import SlackIntegration
import TaskManagerCore
import TaskManagerPersistence

/// Best-effort display metadata is fetched independently of message polling and worker slots.
public actor SlackNameResolver {
    private let store: Store
    private let factory: @Sendable (String, String) throws -> SlackClient
    private var job: Task<Void, Never>?
    private var nextScan = Date.distantPast
    private var stopping = false
    private var cooldowns: [String: Date] = [:]
    public init(store: Store, factory: @escaping @Sendable (String, String) throws -> SlackClient = { workspace, user in
        SlackClient(token: try SlackConnection.token(workspaceID: workspace, userID: user))
    }) { self.store = store; self.factory = factory }

    public func tick(now: Date = Date()) {
        guard !stopping, job == nil, now >= nextScan else { return }
        nextScan = now.addingTimeInterval(15)
        job = Task { _ = try? await self.refresh(); self.finished() }
    }
    private func finished() { job = nil }
    public func shutdown() async { stopping = true; job?.cancel(); await job?.value }

    @discardableResult public func refresh(now: Date = Date()) async throws -> Int {
        let candidates = try await store.slackNameCandidates(now: now, limit: 256)
        let workspaces = try await store.slackWorkspaces()
        var updated = 0, attempted = 0, blocked = Set<String>()
        for (workspace, user) in candidates {
            try Task.checkCancellation()
            guard !blocked.contains(workspace), (cooldowns[workspace] ?? .distantPast) <= now,
                  let connection = workspaces.first(where: { $0.id == workspace }) else { continue }
            guard attempted < 8 else { break }; attempted += 1
            do {
                let client = try factory(workspace, connection.userID)
                let name: SlackUserName
                do { name = try await client.userName(id: user) }
                catch SlackError.rejected(let reason) where user == connection.userID && reason.contains("users:read") {
                    name = try await client.authenticatedUserName(workspaceID: workspace, userID: user)
                }
                try await store.cacheSlackUserName(workspaceID: workspace, user: name, now: now)
                updated += 1
            } catch is CancellationError { throw CancellationError() }
            catch {
                let retry: Date
                if case SlackError.rateLimited(let seconds) = error {
                    retry = now.addingTimeInterval(seconds); blocked.insert(workspace)
                } else {
                    retry = now.addingTimeInterval(3600)
                    blocked.insert(workspace)
                }
                cooldowns[workspace] = retry
                try await store.deferSlackUserName(workspaceID: workspace, userID: user, until: retry)
                try await store.record(taskID: nil, kind: "slack.names.unavailable", detail: "\(workspace): \(error). Showing cached names or IDs; message polling continues.")
            }
        }
        return updated
    }
}
