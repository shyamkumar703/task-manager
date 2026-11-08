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
                                       workerKind: WorkerKind = .codex) async throws -> Int {
        let key = repository.associationKey(pr: pr)
        let cursor = try await store.pollingCursor(sourceKey: key, repository: localRepository, workerKind: workerKind)
        let events = try await client.feedback(in: repository, pr: pr)
        return try await store.commitPoll(sourceKey: key, repository: localRepository, workerKind: workerKind,
                                         expectedGeneration: cursor?.generation, events: events)
    }
}
