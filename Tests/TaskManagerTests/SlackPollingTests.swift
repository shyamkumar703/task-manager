import Foundation
import GitHubIntegration
import SlackIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private actor SlackFixture: SlackHTTPTransport {
    var responses: [SlackHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [SlackHTTPResponse]) { self.responses = responses }
    func get(_ request: URLRequest) throws -> SlackHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ManagerError.invalid("Unexpected Slack request") }
        return responses.removeFirst()
    }
}
private func slackResponse(_ json: String) -> SlackHTTPResponse { SlackHTTPResponse(data: Data(json.utf8)) }

@Test func slackRoutingLookupIsBoundedAndExcludesCurrentAndFutureMessages() async throws {
    let transport = SlackFixture([
        slackResponse(#"{"ok":true,"messages":[{"ts":"1.0","text":"We are discussing export","user":"U"},{"ts":"2.0","text":"Current message"},{"ts":"3.0","text":"Future message"}],"has_more":true,"response_metadata":{"next_cursor":"ignored"}}"#),
        slackResponse(#"{"ok":true,"messages":[{"ts":"1.0","thread_ts":"1.0","text":"Thread root","user":"U"}]}"#),
    ])
    let client = SlackClient(token: "xoxp-fixture", transport: transport)
    let messages = try await client.routingMessages(channel: "C", before: "2.0")
    #expect(messages.map(\.timestamp) == ["1.0"])
    _ = try await client.routingMessages(channel: "C", before: "2.0", thread: "1.0")
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/api/conversations.history")
    #expect(requests[1].url?.path == "/api/conversations.replies")
    #expect(requests[1].url?.query?.contains("ts=1.0") == true)
    #expect(requests.allSatisfy { $0.url?.query?.contains("limit=50") == true })
}
private func slackRoot() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("slack-tests-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}
private func waitSlack(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<300 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ManagerError.invalid("Slack condition timed out")
}

@Test func slackDiscoveryPaginatesIncludingEmptyPagesAndFiltersUnavailableChannels() async throws {
    let transport = SlackFixture([
        slackResponse(#"{"ok":true,"channels":[],"response_metadata":{"next_cursor":"page2"}}"#),
        slackResponse(#"{"ok":true,"channels":[{"id":"C1","name":"project","is_member":true},{"id":"C2","name":"not-joined","is_member":false},{"id":"C3","name":"archived","is_archived":true},{"id":"D1","is_im":true,"user":"U2"},{"id":"G1","name":"Group DM","is_mpim":true}]}"#),
    ])
    let conversations = try await SlackClient(token: "xoxp-fixture", transport: transport).conversations()
    #expect(conversations.map(\.id) == ["C1", "C2", "D1", "G1"])
    #expect(conversations[2].isDM)
    #expect(conversations[2].name == "DM with U2")
    let requests = await transport.requests
    #expect(requests[1].url!.query!.contains("cursor=page2"))
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url!.host == "slack.com" && $0.url!.query!.contains("token=") == false })
}

@Test func slackEditsAndThreadRepliesAreDeduplicatedWithoutReemittingParent() async throws {
    let transport = SlackFixture([
        slackResponse(#"{"ok":true,"messages":[{"ts":"100.1","text":"Original goal","user":"U1","reply_count":1}]}"#),
        slackResponse(#"{"ok":true,"messages":[{"ts":"100.1","text":"Original goal","user":"U1","reply_count":1},{"ts":"101.1","thread_ts":"100.1","text":"Follow-up","user":"U2"},{"ts":"102.1","text":"Bot noise","bot_id":"B1"}]}"#),
        slackResponse(#"{"ok":true,"messages":[{"ts":"100.1","text":"Updated goal","user":"U1","reply_count":2,"edited":{"ts":"200.1"}}]}"#),
        slackResponse(#"{"ok":true,"messages":[{"ts":"100.1","text":"Updated goal","user":"U1","reply_count":2,"edited":{"ts":"200.1"}},{"ts":"101.1","thread_ts":"100.1","text":"Follow-up","user":"U2"},{"ts":"201.1","thread_ts":"100.1","text":"New reply","user":"U3"}]}"#),
    ])
    let client = SlackClient(token: "xoxp-fixture", transport: transport)
    let first = try await client.feedback(workspace: "T1", channel: "C1")
    #expect(first.count == 2)
    #expect(Set(first.map(\.associationKey)) == ["slack:T1:C1:thread:100.1"])
    #expect(first[1].body.contains("Thread context: Original goal"))
    let second = try await client.feedback(workspace: "T1", channel: "C1")
    #expect(second.count == 3)
    #expect(first[0].revision != second[0].revision)
    #expect(first[1].revision == second[1].revision)
    #expect(second[2].sourceID == "T1:C1:201.1")
}

@Test func slackIncompleteAndRepeatedPaginationReturnsNoPartialBatch() async throws {
    let partial = slackResponse(#"{"ok":true,"messages":[{"ts":"1.1","text":"Partial"}],"response_metadata":{"next_cursor":"next"}}"#)
    let denied = slackResponse(#"{"ok":false,"error":"missing_scope"}"#)
    let transport = SlackFixture([partial, denied])
    await #expect(throws: SlackError.self) { try await SlackClient(token: "xoxp-fixture", transport: transport).feedback(workspace: "T1", channel: "C1") }
    let repeated = SlackFixture([partial, partial])
    await #expect(throws: SlackError.self) { try await SlackClient(token: "xoxp-fixture", transport: repeated).feedback(workspace: "T1", channel: "C1") }
    let noCursor = SlackFixture([slackResponse(#"{"ok":true,"messages":[],"has_more":true}"#)])
    await #expect(throws: SlackError.self) { try await SlackClient(token: "xoxp-fixture", transport: noCursor).feedback(workspace: "T1", channel: "C1") }
}

@Test func slackAutomaticPollingBaselinesThenQueuesAndSurvivesRestart() async throws {
    let root = try slackRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite"
    let store = try Store(path: path)
    let id = try await store.addSlackSource(workspaceID: "T1", workspaceName: "Test", userID: "U1", channelID: "C1", channelName: "project", repository: root)
    let transport = SlackFixture([
        slackResponse(#"{"ok":true,"messages":[{"ts":"100.1","text":"Old message","user":"U2"}]}"#),
        slackResponse(#"{"ok":true,"messages":[{"ts":"100.1","text":"Old message","user":"U2"},{"ts":"200.1","text":"New work","user":"U2"}]}"#),
    ])
    let scheduler = SlackPollingScheduler(store: store, factory: { _ in SlackClient(token: "xoxp-fixture", transport: transport) })
    try await scheduler.tick()
    try await waitSlack { try await store.slackSources().first?.lastSuccess != nil }
    #expect(try await store.sources().first?.disposition == .ignored)
    #expect(try await store.sources().first?.reason?.contains("baseline") == true)
    let first = try #require(await store.slackSources().first)
    await scheduler.shutdown()
    let reopened = try Store(path: path)
    let resumed = SlackPollingScheduler(store: reopened, factory: { _ in SlackClient(token: "xoxp-fixture", transport: transport) })
    try await resumed.tick(now: Date(timeIntervalSince1970: first.lastSuccess!))
    #expect(await transport.requests.count == 1)
    try await resumed.tick(now: Date(timeIntervalSince1970: first.nextPoll + 1))
    try await waitSlack { try await reopened.pollingCursor(sourceKey: id, repository: root, workerKind: .codex)?.generation == 2 }
    #expect(try await reopened.sources().count == 2)
    #expect(try await reopened.pendingEventCount() == 1)
    try await reopened.setSlackSourceEnabled(id, enabled: false)
    try await resumed.tick(now: .distantFuture)
    #expect(await transport.requests.count == 2)
    await resumed.shutdown()
}

@Test func slackPollCommitIsAtomicAndRejectsStaleAndCrossConversationBatches() async throws {
    let root = try slackRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let id = try await store.addSlackSource(workspaceID: "T1", workspaceName: "Test", userID: "U1", channelID: "C1", channelName: "project", repository: root)
    try await store.commitSlackPoll(id, expectedGeneration: nil, events: [])
    let event = SourceEvent(integration: "slack", sourceID: "T1:C1:1.1", revision: "v1", associationKey: "slack:T1:C1:thread:1.1", body: "Work", url: "slack://channel?team=T1&id=C1")
    let foreign = SourceEvent(integration: "slack", sourceID: "T1:C2:1.1", revision: "v1", associationKey: "slack:T1:C2:thread:1.1", body: "Foreign", url: "")
    await #expect(throws: ManagerError.self) { try await store.commitSlackPoll(id, expectedGeneration: 1, events: [event, foreign]) }
    #expect(try await store.sources().isEmpty)
    try await store.commitSlackPoll(id, expectedGeneration: 1, events: [event])
    await #expect(throws: ManagerError.self) { try await store.commitSlackPoll(id, expectedGeneration: 1, events: [event]) }
    #expect(try await store.sources().count == 1)
    #expect(try await store.pollingCursor(sourceKey: id, repository: root, workerKind: .codex)?.generation == 2)
}

private actor SlackWorkspaceFixture: SlackHTTPTransport {
    func get(_ request: URLRequest) throws -> SlackHTTPResponse {
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer limited" { return SlackHTTPResponse(data: Data(), status: 429, retryAfter: 600) }
        return slackResponse(#"{"ok":true,"messages":[]}"#)
    }
}
@Test func slackRateLimitPersistsWorkspaceCooldownWithoutBlockingOtherWorkspaces() async throws {
    let root = try slackRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    for (workspace, channel) in [("T1", "C1"), ("T1", "C2"), ("T2", "C3")] {
        try await store.addSlackSource(workspaceID: workspace, workspaceName: workspace, userID: "U1", channelID: channel, channelName: channel, repository: root)
    }
    let transport = SlackWorkspaceFixture()
    let started = Date().timeIntervalSince1970
    let scheduler = SlackPollingScheduler(store: store, factory: { source in SlackClient(token: source.workspaceID == "T1" ? "limited" : "healthy", transport: transport) })
    try await scheduler.tick()
    try await waitSlack {
        let sources = try await store.slackSources()
        return sources.contains { $0.workspaceID == "T1" && $0.failures == 1 } && sources.contains { $0.workspaceID == "T2" && $0.lastSuccess != nil }
    }
    let sources = try await store.slackSources()
    #expect(sources.filter { $0.workspaceID == "T1" }.allSatisfy { $0.nextPoll >= started + 600 })
    #expect(try await store.pollingCursor(sourceKey: "slack:T1:C1", repository: root, workerKind: .codex) == nil)
    await scheduler.shutdown()
}

@Test func slackSchemaUpgradePreservesExistingTasksAndGitHubSources() async throws {
    let root = try slackRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite"
    let store = try Store(path: path)
    let task = try await store.createAgentTask(goal: "Existing task", repository: root, kind: .mock)
    try await store.addGitHubSource(repository: "o/r", localRepository: root, author: "me")
    let sqlite = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
    #expect(try await sqlite.run(arguments: [path, "DROP TABLE slack_sources; PRAGMA user_version = 6;"]).exitCode == 0)
    let upgraded = try Store(path: path)
    #expect(try await upgraded.task(task.id).goal == task.goal)
    #expect(try await upgraded.gitHubSources().count == 1)
    try await upgraded.addSlackSource(workspaceID: "T1", workspaceName: "Test", userID: "U1", channelID: "D1", channelName: "DM", repository: root)
    #expect(try await upgraded.slackSources().count == 1)
}

private struct SlackConflictTriage: TriageEngine {
    let taskID: String
    func decide(event: IncomingSource, candidates: [TriageCandidate]) async throws -> TriageDecision {
        if event.clarification != nil { return .init(action: .ignore, reason: "User kept the original Swift requirement") }
        return .init(action: .conflict, taskID: taskID, reason: "Python contradicts the Swift instruction", question: "Keep Swift or change to Python?")
    }
}
@Test func polledSlackConflictUsesExistingQuestionAndUserAnswerPipeline() async throws {
    let root = try slackRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Implement in Swift", repository: root, kind: .mock)
    try await store.transition(task.id, to: .paused)
    let id = try await store.addSlackSource(workspaceID: "T1", workspaceName: "Test", userID: "U1", channelID: "C1", channelName: "project", repository: root)
    try await store.commitSlackPoll(id, expectedGeneration: nil, events: [])
    let transport = SlackFixture([slackResponse(#"{"ok":true,"messages":[{"ts":"100.1","text":"Change the implementation to Python","user":"U2"}]}"#)])
    let scheduler = SlackPollingScheduler(store: store, factory: { _ in SlackClient(token: "xoxp-fixture", transport: transport) })
    try await scheduler.tick(now: .distantFuture)
    try await waitSlack { try await store.pendingEventCount() == 1 }
    await scheduler.shutdown()
    let triage = SourceTriage(store: store, engine: SlackConflictTriage(taskID: task.id))
    try await triage.tick()
    try await waitSlack { try await store.sources().first?.disposition == .waitingForUser }
    let event = try #require(await store.sources().first)
    #expect(event.integration == "slack")
    #expect(event.question?.contains("Keep Swift") == true)
    #expect(try await store.messages(taskID: task.id).isEmpty)
    #expect(try await store.task(task.id).status == .paused)
    try await store.answerSource(eventID: event.id, text: "Keep Swift; ignore the proposed rewrite")
    try await waitSlack {
        try await triage.tick()
        return try await store.source(event.id).disposition == .ignored
    }
    #expect(try await store.messages(taskID: task.id).isEmpty)
    await triage.shutdown()
}

@Test func slackPartialFetchFailureLeavesEventsAndCursorUntouched() async throws {
    let root = try slackRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.addSlackSource(workspaceID: "T1", workspaceName: "Test", userID: "U1", channelID: "C1", channelName: "project", repository: root)
    let transport = SlackFixture([
        slackResponse(#"{"ok":true,"messages":[{"ts":"1.1","text":"Partial work"}],"response_metadata":{"next_cursor":"next"}}"#),
        slackResponse(#"{"ok":false,"error":"missing_scope"}"#),
    ])
    let scheduler = SlackPollingScheduler(store: store, factory: { _ in SlackClient(token: "xoxp-fixture", transport: transport) })
    try await scheduler.tick()
    try await waitSlack { try await store.slackSources().first?.failures == 1 }
    #expect(try await store.slackSources().first?.lastError?.contains("missing_scope") == true)
    #expect(try await store.sources().isEmpty)
    #expect(try await store.pollingCursor(sourceKey: id, repository: root, workerKind: .codex) == nil)
    await scheduler.shutdown()
}
