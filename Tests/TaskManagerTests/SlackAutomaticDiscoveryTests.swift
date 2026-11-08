import Foundation
import SlackIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private actor AutoSlackHTTP: SlackHTTPTransport {
    var discoveryCalls = 0
    var historyCalls = 0
    func get(_ request: URLRequest) throws -> SlackHTTPResponse {
        let body: String
        if request.url!.path.hasSuffix("conversations.list") {
            discoveryCalls += 1
            let extra = discoveryCalls > 1 ? #",{"id":"C2","name":"new-public-channel","is_member":false}"# : ""
            body = #"{"ok":true,"channels":[{"id":"C1","name":"public","is_member":false},{"id":"D1","user":"U2","is_im":true}"# + extra + "]}"
        } else {
            historyCalls += 1
            body = #"{"ok":true,"messages":[]}"#
        }
        return SlackHTTPResponse(data: Data(body.utf8))
    }
}
private func autoRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slack-auto-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}
private func autoWait(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<300 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ManagerError.invalid("Automatic discovery timed out")
}

@Test func connectedWorkspaceAutomaticallyDiscoversAllConversationsAndNewChannels() async throws {
    let root = try autoRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let connection = try SlackConnection.validateAuthentication(data: Data(#"{"ok":true,"team_id":"T1","team":"Test","user_id":"U1"}"#.utf8), status: 200)
    let transport = AutoSlackHTTP()
    let scheduler = SlackPollingScheduler(store: store, connections: { [connection] }, discoveryFactory: { _, _ in SlackClient(token: "fixture", transport: transport) }, factory: { _ in SlackClient(token: "fixture", transport: transport) })
    // No manual sources, project path, or TUI interaction.
    try await scheduler.tick()
    try await autoWait { try await store.slackSources().count == 2 }
    let initial = try await store.slackSources()
    #expect(initial.allSatisfy { $0.repository.isEmpty && $0.enabled })
    #expect(Set(initial.map(\.channelID)) == ["C1", "D1"])
    // Explicit pauses survive later automatic rediscovery; a new public channel is enrolled.
    for source in initial { try await store.setSlackSourceEnabled(source.id, enabled: false) }
    try await scheduler.tick(now: .distantFuture)
    try await autoWait { try await store.slackSources().count == 3 }
    let updated = try await store.slackSources()
    #expect(updated.filter { $0.channelID != "C2" }.allSatisfy { !$0.enabled })
    #expect(updated.first { $0.channelID == "C2" }?.enabled == true)
    try await scheduler.tick()
    try await autoWait { try await store.slackSources().first(where: { $0.channelID == "C2" })?.lastSuccess != nil }
    #expect(try await store.pollingCursor(sourceKey: "slack:T1:C2", repository: "", workerKind: .codex)?.generation == 1)
    await scheduler.shutdown()
    let reopened = try Store(path: root + "/state.sqlite")
    #expect(try await reopened.slackSources().count == 3)
    #expect(try await reopened.slackWorkspaces().first?.lastSuccess != nil)
    #expect(try await reopened.pollingCursor(sourceKey: "slack:T1:C2", repository: "", workerKind: .codex)?.generation == 1)
}

private func slackEvent(_ revision: String) -> SourceEvent {
    SourceEvent(integration: "slack", sourceID: "T1:C1:1.1", revision: revision, associationKey: "slack:T1:C1:thread:1.1", body: "Follow-up for the second project", url: "slack://channel?team=T1&id=C1")
}
@Test func unboundSlackRoutesAcrossProjectsAndRetainsAssociationAcrossPolls() async throws {
    let root = try autoRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let first = root + "/first", second = root + "/second"
    for path in [first, second] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    let store = try Store(path: root + "/state.sqlite")
    let one = try await store.createAgentTask(goal: "First project", repository: first, kind: .mock)
    let two = try await store.createAgentTask(goal: "Second project", repository: second, kind: .mock)
    for task in [one, two] { try await store.transition(task.id, to: .paused) }
    let id = try await store.addSlackSource(workspaceID: "T1", workspaceName: "Test", userID: "U1", channelID: "C1", channelName: "all")
    try await store.commitSlackPoll(id, expectedGeneration: nil, events: [])
    try await store.commitSlackPoll(id, expectedGeneration: 1, events: [slackEvent("v1")])
    let event = try #require(await store.claimTriageEvent())
    #expect(event.repository.isEmpty)
    #expect(Set(event.availableRepositories ?? []) == [first, second])
    #expect(try await store.triageCandidates(repository: "").count == 2)
    try await store.applyTriage(eventID: event.id, decision: .init(action: .route, taskID: two.id, reason: "Affects the second project's existing work"))
    #expect(try await store.source(event.id).repository == second)
    #expect(try await store.messages(taskID: one.id).isEmpty)
    #expect(try await store.messages(taskID: two.id).count == 1)
    // Re-fetching a resolved revision must preserve its project, while new revisions remain global.
    try await store.commitSlackPoll(id, expectedGeneration: 2, events: [slackEvent("v1"), slackEvent("v2")])
    try await store.routeKnownEvents()
    let followup = try #require(await store.claimTriageEvent())
    #expect(followup.taskID == two.id)
    try await store.applyTriage(eventID: followup.id, decision: .init(action: .conflict, taskID: two.id, reason: "Contradicts the current approach", question: "Keep the current approach?"))
    #expect(try await store.source(followup.id).disposition == .waitingForUser)
    #expect(try await store.messages(taskID: two.id).count == 1)
}

@Test func unboundNewWorkAsksForProjectAndAcceptsExplicitUserPath() async throws {
    let root = try autoRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.addSlackSource(workspaceID: "T1", workspaceName: "Test", userID: "U1", channelID: "C1", channelName: "all")
    try await store.commitSlackPoll(id, expectedGeneration: nil, events: [])
    try await store.commitSlackPoll(id, expectedGeneration: 1, events: [slackEvent("v1")])
    let event = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: event.id, decision: .init(action: .create, goal: "Implement export", reason: "Actionable request without an obvious project"))
    #expect(try await store.tasks().isEmpty)
    #expect(try await store.source(event.id).question?.contains("local project") == true)
    try await store.answerSource(eventID: event.id, text: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: event.id, decision: .init(action: .create, goal: "Implement export", reason: "User identified the project"))
    let taskID = try #require(await store.source(event.id).taskID)
    #expect(try await store.agentSession(taskID: taskID)?.repository == root)
}

@Test func globalSlackCreationCanSelectKnownProjectButCannotInventOne() async throws {
    let root = try autoRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    try await store.registerProject(repository: root)
    let id = try await store.addSlackSource(workspaceID: "T1", workspaceName: "Test", userID: "U1", channelID: "C1", channelName: "all")
    try await store.commitSlackPoll(id, expectedGeneration: nil, events: [])
    let unrelated = SourceEvent(integration: "slack", sourceID: "T1:C1:2.2", revision: "v1", associationKey: "slack:T1:C1:thread:2.2", body: "Distinct work", url: "")
    try await store.commitSlackPoll(id, expectedGeneration: 1, events: [slackEvent("v1"), unrelated])
    let first = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: first.id, decision: .init(action: .create, goal: "Export", reason: "Clearly identifies a known project", repository: root))
    #expect(try await store.tasks().count == 1)
    let second = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: second.id, decision: .init(action: .create, goal: "Invented", reason: "Unsafe project", repository: "/invented"))
    #expect(try await store.source(second.id).disposition == .waitingForUser)
    #expect(try await store.tasks().count == 1)
}

private actor AutoDiscoveryRateLimit: SlackHTTPTransport {
    func get(_ request: URLRequest) -> SlackHTTPResponse {
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer limited" { return SlackHTTPResponse(data: Data(), status: 429, retryAfter: 600) }
        return SlackHTTPResponse(data: Data(#"{"ok":true,"channels":[]}"#.utf8))
    }
}
@Test func automaticDiscoveryFailuresBackOffWithoutBlockingAnotherConnectedWorkspace() async throws {
    let root = try autoRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let connections = try ["T1", "T2"].map { id in
        try SlackConnection.validateAuthentication(data: Data("{\"ok\":true,\"team_id\":\"\(id)\",\"team\":\"Test\",\"user_id\":\"U1\"}".utf8), status: 200)
    }
    let transport = AutoDiscoveryRateLimit()
    let scheduler = SlackPollingScheduler(store: store, connections: { connections }, discoveryFactory: { workspace, _ in SlackClient(token: workspace == "T1" ? "limited" : "healthy", transport: transport) })
    let started = Date().timeIntervalSince1970
    try await scheduler.tick()
    try await autoWait {
        let workspaces = try await store.slackWorkspaces()
        return workspaces.contains { $0.id == "T1" && $0.failures == 1 } && workspaces.contains { $0.id == "T2" && $0.lastSuccess != nil }
    }
    let limited = try #require(await store.slackWorkspaces().first(where: { $0.id == "T1" }))
    #expect(limited.nextDiscovery >= started + 600)
    #expect(limited.lastError?.contains("rate limit") == true)
    await scheduler.shutdown()
    let reopened = try Store(path: root + "/state.sqlite")
    #expect(try await reopened.slackWorkspaces().first(where: { $0.id == "T1" })?.failures == 1)
}
