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

private func pollResponse(_ json: String) -> HTTPResponse { HTTPResponse(data: Data(json.utf8), status: 200) }
private let ownPR = #"{"number":1,"title":"First","user":{"login":"me"},"head":{"sha":"abc"}}"#
private let newPR = #"{"number":2,"title":"Second","user":{"login":"me"},"head":{"sha":"def"}}"#
private let foreignPR = #"{"number":9,"title":"Other","user":{"login":"someone"},"head":{"sha":"xyz"}}"#
private func commentJSON(_ id: Int, _ body: String) -> String {
    "{\"id\":\(id),\"body\":\"\(body)\",\"html_url\":\"https://github.com/o/r/pull/1\",\"updated_at\":\"v1\"}"
}
private func waitForPoll(_ store: Store, _ predicate: (GitHubSource) -> Bool) async throws {
    for _ in 0..<300 {
        if let source = try await store.gitHubSources().first, predicate(source) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ManagerError.invalid("Polling did not finish")
}

@Test func automaticRepositoryPollingDiscoversOwnPRsAndResumesAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = try Store(path: path)
    let id = try await store.addGitHubSource(repository: "o/r", localRepository: root.path, author: "me", intervalSeconds: 60)
    let empty = pollResponse("[]")
    let transport = PollTransport([
        pollResponse("[\(ownPR),\(foreignPR)]"), pollResponse("[\(commentJSON(1, "old"))]"), empty, empty,
        pollResponse("[\(ownPR),\(newPR)]"), pollResponse("[\(commentJSON(1, "old")),\(commentJSON(2, "new"))]"), empty, empty,
        pollResponse("[\(commentJSON(3, "new PR feedback"))]"), empty, empty,
    ])
    let scheduler = GitHubPollingScheduler(store: store, client: try GitHubClient(transport: transport))
    try await scheduler.tick()
    try await waitForPoll(store) { $0.lastSuccess != nil }
    #expect(try await store.sources().count == 1)
    #expect(try await store.pendingEventCount() == 0)
    let initial = try #require(await store.gitHubSources().first)
    #expect(initial.nextPoll >= initial.lastSuccess! + 60)
    await scheduler.shutdown()
    let reopened = try Store(path: path)
    let resumed = GitHubPollingScheduler(store: reopened, client: try GitHubClient(transport: transport))
    // A restart before the due time must not fetch or advance any cursor.
    try await resumed.tick(now: Date(timeIntervalSince1970: initial.lastSuccess!))
    #expect(try await reopened.pollingCursor(sourceKey: "github:o/r:pr:1", repository: root.path, workerKind: .codex)?.generation == 1)
    try await resumed.tick(now: Date(timeIntervalSince1970: initial.nextPoll + 1))
    try await waitForPoll(reopened) { ($0.lastSuccess ?? 0) > initial.lastSuccess! }
    #expect(try await reopened.pendingEventCount() == 2)
    #expect(try await reopened.sources().count == 3)
    try await reopened.setGitHubSourceEnabled(id, enabled: false)
    try await resumed.tick(now: .distantFuture)
    #expect(try await reopened.gitHubSources().first?.enabled == false)
    #expect(try await reopened.pollingCursor(sourceKey: "github:o/r:pr:1", repository: root.path, workerKind: .codex)?.generation == 2)
    await resumed.shutdown()
}

@Test func automaticPollingPersistsFailuresAndHonorsRateLimitBackoff() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("state.sqlite").path)
    try await store.addGitHubSource(repository: "o/r", localRepository: root.path, author: "me", intervalSeconds: 10)
    let retry = Date().timeIntervalSince1970 + 600
    let transport = PollTransport([HTTPResponse(data: Data(), status: 403, headers: ["x-ratelimit-reset": String(retry)])])
    let scheduler = GitHubPollingScheduler(store: store, client: try GitHubClient(transport: transport))
    try await scheduler.tick()
    try await waitForPoll(store) { $0.failures == 1 }
    let source = try #require(await store.gitHubSources().first)
    #expect(source.lastSuccess == nil)
    #expect(source.lastError?.contains("403") == true)
    #expect(source.nextPoll >= retry)
    #expect(try await store.sources().isEmpty)
    try await scheduler.tick()
    #expect(try await store.gitHubSources().first?.failures == 1)
    await scheduler.shutdown()
}

private actor RepositoryPollTransport: GitHubHTTPTransport {
    func get(_ request: URLRequest) throws -> HTTPResponse {
        if request.url!.path.contains("/broken/") { return HTTPResponse(data: Data(), status: 503) }
        return pollResponse("[]")
    }
}

@Test func repositoryPollingFailuresDoNotBlockOtherConfiguredRepositories() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: ":memory:")
    try await store.addGitHubSource(repository: "o/broken", localRepository: root.path, author: "me")
    try await store.addGitHubSource(repository: "o/healthy", localRepository: root.path, author: "me")
    let scheduler = GitHubPollingScheduler(store: store, client: try GitHubClient(transport: RepositoryPollTransport()))
    try await scheduler.tick()
    for _ in 0..<300 {
        let sources = try await store.gitHubSources()
        if sources[0].failures == 1 && sources[1].lastSuccess != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let sources = try await store.gitHubSources()
    #expect(sources[0].lastError?.contains("503") == true)
    #expect(sources[1].lastSuccess != nil)
    #expect(sources[1].failures == 0)
    await scheduler.shutdown()
}

@Test func repositoryPollingMigrationPreservesExistingCursor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = try Store(path: path)
    try await store.commitPoll(sourceKey: "github:o/r:pr:1", repository: root.path, workerKind: .codex, expectedGeneration: nil, events: [feedback("v1")])
    let sqlite = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
    let fixture = try await sqlite.run(arguments: [path, "DROP TABLE github_sources; PRAGMA user_version = 5;"])
    #expect(fixture.exitCode == 0)
    let upgraded = try Store(path: path)
    #expect(try await upgraded.pollingCursor(sourceKey: "github:o/r:pr:1", repository: root.path, workerKind: .codex)?.generation == 1)
    #expect(try await upgraded.sources().count == 1)
    try await upgraded.addGitHubSource(repository: "o/r", localRepository: root.path, author: "me")
    #expect(try await upgraded.gitHubSources().count == 1)
}
