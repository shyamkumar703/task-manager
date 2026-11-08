import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private func feedback(_ revision: String, id: String = "comment:1") -> SourceEvent {
    SourceEvent(integration: "github", sourceID: id, revision: revision, associationKey: "github:o/r:pr:1", body: "Feedback \(revision)", url: "https://github.com/o/r/pull/1")
}

@Test func pollCursorSurvivesRestartBaselinesHistoryAndDeduplicatesEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = try Store(path: path)
    let key = "github:o/r:pr:1"
    #expect(try await store.commitPoll(sourceKey: key, repository: root.path, workerKind: .mock, expectedGeneration: nil, events: [feedback("v1")]) == 1)
    #expect(try await store.sources().first?.disposition == .ignored)
    #expect(try await store.pendingEventCount() == 0)
    let reopened = try Store(path: path)
    #expect(try await reopened.pollingCursor(sourceKey: key, repository: root.path, workerKind: .mock)?.generation == 1)
    #expect(try await reopened.commitPoll(sourceKey: key, repository: root.path, workerKind: .mock, expectedGeneration: 1, events: [feedback("v1"), feedback("v2"), feedback("v1", id: "comment:2")]) == 2)
    #expect(try await reopened.pendingEventCount() == 2)
    #expect(try await reopened.commitPoll(sourceKey: key, repository: root.path, workerKind: .mock, expectedGeneration: 2, events: [feedback("v2")]) == 0)
    await #expect(throws: ManagerError.self) {
        try await store.commitPoll(sourceKey: key, repository: root.path, workerKind: .mock, expectedGeneration: 1, events: [feedback("stale")])
    }
    #expect(try await reopened.sources().count == 3)
    #expect(try await reopened.pollingCursor(sourceKey: key, repository: root.path, workerKind: .mock)?.generation == 3)
}

@Test func pollBatchRollbackPreservesCursorAndAllEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: ":memory:")
    try await store.commitPoll(sourceKey: "github:o/r:pr:1", repository: root.path, workerKind: .mock, expectedGeneration: nil, events: [])
    try await store.ingest([feedback("foreign")], repository: other.path)
    await #expect(throws: ManagerError.self) {
        try await store.commitPoll(sourceKey: "github:o/r:pr:1", repository: root.path, workerKind: .mock, expectedGeneration: 1, events: [feedback("new"), feedback("foreign")])
    }
    #expect(try await store.sources().count == 1)
    #expect(try await store.pollingCursor(sourceKey: "github:o/r:pr:1", repository: root.path, workerKind: .mock)?.generation == 1)
}

private actor PollTransport: GitHubHTTPTransport {
    var responses: [HTTPResponse]
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func get(_ request: URLRequest) throws -> HTTPResponse {
        guard !responses.isEmpty else { throw ManagerError.invalid("Unexpected request") }
        return responses.removeFirst()
    }
}

@Test func incompleteGitHubPollNeverAdvancesCursor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: ":memory:")
    let ok = HTTPResponse(data: Data("[]".utf8), status: 200)
    let failed = HTTPResponse(data: Data(), status: 500)
    let client = try GitHubClient(transport: PollTransport([ok, failed, ok, ok, ok, ok, failed]))
    let poller = GitHubPoller(store: store, client: client)
    let repo = try GitHubRepository("o/r")
    await #expect(throws: GitHubError.self) {
        try await poller.poll(repository: repo, pr: 1, localRepository: root.path)
    }
    #expect(try await store.pollingCursor(sourceKey: repo.associationKey(pr: 1), repository: root.path, workerKind: .codex) == nil)
    try await poller.poll(repository: repo, pr: 1, localRepository: root.path)
    await #expect(throws: GitHubError.self) {
        try await poller.poll(repository: repo, pr: 1, localRepository: root.path)
    }
    #expect(try await store.pollingCursor(sourceKey: repo.associationKey(pr: 1), repository: root.path, workerKind: .codex)?.generation == 1)
}
