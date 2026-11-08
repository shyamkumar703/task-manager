import Foundation
import SlackIntegration
import TaskManagerCore
import TaskManagerPersistence

public struct SlackDiscoveredConversation: Sendable, Codable {
    public let connection: SlackConnectionInfo
    public let conversation: SlackConversation
}
public enum SlackDiscovery {
    public static func discover(stateDirectory: String) async throws -> [SlackDiscoveredConversation] {
        var result: [SlackDiscoveredConversation] = []
        for connection in try SlackConnection.connections(stateDirectory: stateDirectory) {
            let token = try SlackConnection.token(workspaceID: connection.workspaceID, userID: connection.userID)
            let conversations = try await SlackClient(token: token).conversations()
            result += conversations.map { SlackDiscoveredConversation(connection: connection, conversation: $0) }
        }
        return result
    }
}

public actor SlackPollingScheduler {
    public typealias ClientFactory = @Sendable (SlackSource) throws -> SlackClient
    private let store: Store
    private let factory: ClientFactory
    private var jobs: [String: Task<Void, Never>] = [:]
    private var workspaces: [String: String] = [:]
    private var stopping = false
    public init(store: Store, factory: @escaping ClientFactory = { source in
        SlackClient(token: try SlackConnection.token(workspaceID: source.workspaceID, userID: source.userID))
    }) { self.store = store; self.factory = factory }
    public func tick(now: Date = Date()) async throws {
        guard !stopping else { return }
        let sources = try await store.slackSources()
        for source in sources where !source.enabled { jobs[source.id]?.cancel() }
        for source in sources where source.enabled && source.nextPoll <= now.timeIntervalSince1970 && jobs[source.id] == nil && jobs.count < 2 && workspaces[source.workspaceID] == nil {
            workspaces[source.workspaceID] = source.id
            jobs[source.id] = Task { await self.run(source) }
        }
    }
    public func shutdown() async {
        stopping = true
        let pending = Array(jobs.values)
        pending.forEach { $0.cancel() }
        for job in pending { await job.value }
    }
    private func run(_ source: SlackSource) async {
        defer { jobs[source.id] = nil; workspaces[source.workspaceID] = nil }
        do {
            let cursor = try await store.pollingCursor(sourceKey: source.id, repository: source.repository, workerKind: .codex)
            let client = try factory(source)
            let events = try await client.feedback(workspace: source.workspaceID, channel: source.channelID)
            try Task.checkCancellation()
            try await store.commitSlackPoll(source.id, expectedGeneration: cursor?.generation, events: events)
        } catch {
            guard !Task.isCancelled else { return }
            let retry: Double?
            if case SlackError.rateLimited(let seconds) = error { retry = Date().timeIntervalSince1970 + seconds }
            else { retry = nil }
            try? await store.failSlackPoll(source.id, error: String(describing: error), retryAfter: retry)
        }
    }
}
