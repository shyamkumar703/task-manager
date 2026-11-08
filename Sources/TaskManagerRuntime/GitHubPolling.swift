import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence

public struct GitHubPoller: Sendable {
    private let store: Store
    private let client: GitHubClient

    public init(store: Store, client: GitHubClient) { self.store = store; self.client = client }

    /// Re-fetch every feedback endpoint: reviews have no reliable edit timestamp watermark.
    /// Failed or incomplete pagination never advances the durable cursor.
    @discardableResult public func poll(repository: GitHubRepository, pr: Int, localRepository: String,
                                       workerKind: WorkerKind = .codex, baselineFirst: Bool = true) async throws -> Int {
        let key = repository.associationKey(pr: pr)
        let cursor = try await store.pollingCursor(sourceKey: key, repository: localRepository, workerKind: workerKind)
        let events = try await client.feedback(in: repository, pr: pr)
        return try await store.commitPoll(sourceKey: key, repository: localRepository, workerKind: workerKind,
                                         expectedGeneration: cursor?.generation, events: events, baselineFirst: baselineFirst)
    }
}

/// Repository polling is independent of child workers and master triage.
public actor GitHubPollingScheduler {
    private let store: Store
    private let client: GitHubClient
    private var jobs: [String: Task<Void, Never>] = [:]
    private var stopping = false

    public init(store: Store, client: GitHubClient) { self.store = store; self.client = client }

    public func tick(now: Date = Date()) async throws {
        guard !stopping else { return }
        let sources = try await store.gitHubSources()
        for source in sources where !source.enabled { jobs[source.id]?.cancel() }
        for source in sources where source.enabled && source.nextPoll <= now.timeIntervalSince1970 && jobs[source.id] == nil && jobs.count < 2 {
            jobs[source.id] = Task { await self.run(source) }
        }
    }

    public func shutdown() async {
        stopping = true
        let pending = Array(jobs.values)
        pending.forEach { $0.cancel() }
        for job in pending { await job.value }
    }

    private func run(_ source: GitHubSource) async {
        defer { jobs[source.id] = nil }
        do {
            let repository = try GitHubRepository(source.repository)
            let pulls = try await client.openPullRequests(in: repository, author: source.author)
            let poller = GitHubPoller(store: store, client: client)
            for pull in pulls {
                try Task.checkCancellation()
                try await poller.poll(repository: repository, pr: pull.number, localRepository: source.localRepository,
                                      baselineFirst: source.lastSuccess == nil)
            }
            try Task.checkCancellation()
            try await store.finishGitHubPoll(source.id, error: nil)
        } catch {
            guard !Task.isCancelled else { return }
            var retryAt: Double?
            if case GitHubError.http(_, let retry) = error, let retry, let value = Double(retry) {
                // gh exposes either Retry-After seconds or the rate-limit reset epoch.
                retryAt = value > 1_000_000_000 ? value : Date().timeIntervalSince1970 + value
            }
            try? await store.finishGitHubPoll(source.id, error: String(describing: error), retryAfter: retryAt)
        }
    }
}
