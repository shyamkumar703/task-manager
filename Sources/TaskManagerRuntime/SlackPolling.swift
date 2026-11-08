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
    private let connections: @Sendable () throws -> [SlackConnectionInfo]
    private let discoveryFactory: @Sendable (String, String) throws -> SlackClient
    private var jobs: [String: Task<Void, Never>] = [:]
    private var workspaces: [String: String] = [:]
    private var stopping = false
    private var cachedConnections: [SlackConnectionInfo] = []
    private var nextConnectionRead = Date.distantPast
    public init(store: Store, stateDirectory: String? = nil,
                connections: (@Sendable () throws -> [SlackConnectionInfo])? = nil,
                discoveryFactory: @escaping @Sendable (String, String) throws -> SlackClient = { workspace, user in
                    SlackClient(token: try SlackConnection.token(workspaceID: workspace, userID: user))
                },
                factory: @escaping ClientFactory = { source in
                    SlackClient(token: try SlackConnection.token(workspaceID: source.workspaceID, userID: source.userID))
                }) {
        self.store = store; self.factory = factory; self.discoveryFactory = discoveryFactory
        self.connections = connections ?? { try stateDirectory.map { try SlackConnection.connections(stateDirectory: $0) } ?? [] }
    }
    public func tick(now: Date = Date()) async throws {
        guard !stopping else { return }
        if now >= nextConnectionRead {
            do {
                cachedConnections = try connections()
                nextConnectionRead = now.addingTimeInterval(5)
            } catch {
                nextConnectionRead = now.addingTimeInterval(60)
                try? await store.record(taskID: nil, kind: "slack.connection.failed", detail: "Could not read saved Slack connection metadata; retrying in 60 seconds")
            }
        }
        let connected = cachedConnections
        for connection in connected {
            try await store.ensureSlackWorkspace(id: connection.workspaceID, name: connection.workspaceName, userID: connection.userID)
        }
        let workspaceStates = try await store.slackWorkspaces()
        let sources = try await store.slackSources()
        // Pick discovery when its deadline precedes every conversation deadline.
        // This keeps discovery and message polling fair even in large workspaces.
        for workspace in workspaceStates where workspace.nextDiscovery <= now.timeIntervalSince1970 && workspaces[workspace.id] == nil && jobs.count < 2 && connected.contains(where: { $0.workspaceID == workspace.id }) {
            let nextMessage = sources.filter { $0.workspaceID == workspace.id && $0.enabled }.map(\.nextPoll).min() ?? .infinity
            if workspace.nextDiscovery <= nextMessage {
                let key = "discovery:" + workspace.id
                workspaces[workspace.id] = key
                jobs[key] = Task { await self.discover(workspace, key: key) }
            }
        }
        for source in sources where !source.enabled { jobs[source.id]?.cancel() }
        for source in sources where source.enabled && source.nextPoll <= now.timeIntervalSince1970 && jobs[source.id] == nil && jobs.count < 2 && workspaces[source.workspaceID] == nil {
            workspaces[source.workspaceID] = source.id
            jobs[source.id] = Task { await self.run(source) }
        }
        for workspace in workspaceStates where workspace.nextDiscovery <= now.timeIntervalSince1970 && workspaces[workspace.id] == nil && jobs.count < 2 && connected.contains(where: { $0.workspaceID == workspace.id }) {
            let key = "discovery:" + workspace.id
            workspaces[workspace.id] = key
            jobs[key] = Task { await self.discover(workspace, key: key) }
        }
    }
    public func shutdown() async {
        stopping = true
        let pending = Array(jobs.values)
        pending.forEach { $0.cancel() }
        for job in pending { await job.value }
    }
    private func discover(_ workspace: SlackWorkspace, key: String) async {
        defer { jobs[key] = nil; workspaces[workspace.id] = nil }
        do {
            let client = try discoveryFactory(workspace.id, workspace.userID)
            let conversations = try await client.conversations()
            try Task.checkCancellation()
            try await store.reconcileSlackConversations(workspaceID: workspace.id, conversations: conversations)
        } catch {
            guard !Task.isCancelled else { return }
            let retry: Double?
            if case SlackError.rateLimited(let seconds) = error { retry = Date().timeIntervalSince1970 + seconds }
            else { retry = nil }
            try? await store.failSlackDiscovery(workspace.id, error: String(describing: error), retryAfter: retry)
        }
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
