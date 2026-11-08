import Foundation
import SlackIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private func contextRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slack-context-" + UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}
private func contextEvent(_ timestamp: String, text: String, thread: String? = nil, channel: String = "C1", revision: String = "v1") -> SourceEvent {
    let root = thread ?? timestamp
    return SourceEvent(integration: "slack", sourceID: "T1:\(channel):\(timestamp)", revision: revision, associationKey: "slack:T1:\(channel):thread:\(root)", body: "Author: U1\nChannel: \(channel)\n\n\(text)", url: "slack://channel?team=T1&id=\(channel)", slackMessage: SlackMessage(timestamp: timestamp, threadTimestamp: root, author: "U1", text: text))
}
private func contextStore(_ path: String) async throws -> Store {
    let store = try Store(path: path)
    try await store.ensureSlackWorkspace(id: "T1", name: "Personal", userID: "U1")
    try await store.reconcileSlackConversations(workspaceID: "T1", conversations: [SlackConversation(id: "C1", name: "todo-development", isDM: false, topic: "Todo CLI", purpose: "Build the todo list app"), SlackConversation(id: "C2", name: "another-project", isDM: false)])
    return store
}

@Test func slackRoutingContextIsBoundedChronologicalIsolatedAndSavedAcrossRestart() async throws {
    let root = try contextRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite"
    let store = try await contextStore(path)
    var history = (1...30).map { contextEvent(String(1000 + $0), text: "Todo app discussion \($0): " + String(repeating: "x", count: 1000), thread: "900") }
    history += [contextEvent("900", text: "Root discussion of the todo app"), contextEvent("950", text: "Storage details", thread: "900")]
    // Deliberately reverse ingestion order: context ordering must follow Slack timestamps.
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: nil, events: history.reversed())
    try await store.commitSlackPoll("slack:T1:C2", expectedGeneration: nil, events: [contextEvent("1500", text: "Do not leak this other channel", channel: "C2")])
    let question = contextEvent("2000", text: "How does storage work?", thread: "900")
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 1, events: [question, contextEvent("3000", text: "Future unrelated project announcement")])
    let event = try #require(await store.claimTriageEvent())
    let context = try #require(event.slackContext)
    #expect(context.channelName == "todo-development")
    #expect(context.topic == "Todo CLI")
    #expect(context.purpose == "Build the todo list app")
    #expect(context.precedingMessages.count == 8)
    #expect(context.precedingMessages.allSatisfy { Double($0.timestamp)! < 2000 && $0.text.count <= 700 })
    #expect(context.precedingMessages.map { Double($0.timestamp)! } == context.precedingMessages.map { Double($0.timestamp)! }.sorted())
    #expect(context.threadMessages.count == 12)
    #expect(context.threadMessages.first?.timestamp == "900")
    #expect(context.threadMessages.last?.timestamp == "1030")
    let encoded = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    #expect(!encoded.contains("Do not leak"))
    #expect(!encoded.contains("Future unrelated"))
    #expect(encoded.count < 22000)
    try await store.reconcileSlackConversations(workspaceID: "T1", conversations: [SlackConversation(id: "C1", name: "renamed", isDM: false, topic: "New topic")])
    #expect(try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 2, events: [question]) == 0)
    let reopened = try Store(path: path)
    #expect(try await reopened.source(event.id).slackContext?.channelName == "todo-development")
    #expect(try await reopened.source(event.id).slackContext?.topic == "Todo CLI")
}

@Test func slackContextCarriesEarlierUserProjectClarificationWithoutBindingEntireChannel() async throws {
    let root = try contextRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let other = root + "/other"
    try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
    let store = try await contextStore(root + "/state.sqlite")
    for path in [root, other] { try await store.registerProject(repository: path) }
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: nil, events: [])
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 1, events: [contextEvent("1000", text: "What commands are in the todo app?")])
    let previous = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: previous.id, decision: .init(action: .clarify, reason: "Old policy lacked conversation context", question: "Which project?"))
    try await store.answerSource(eventID: previous.id, text: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: previous.id, decision: .init(action: .investigate, goal: "Explain the todo CLI", reason: "User identified the todo project"))
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 2, events: [contextEvent("2000", text: "How does storage work?")])
    let followup = try #require(await store.claimTriageEvent())
    #expect(followup.repository.isEmpty)
    #expect(Set(followup.availableRepositories ?? []) == [root, other])
    let evidence = try #require(followup.slackContext?.projectHistory.first)
    #expect(evidence.repository == root)
    #expect(evidence.userClarification?.contains(root) == true)
    #expect(followup.slackContext?.precedingMessages.first?.text.contains("todo app") == true)
    // Context is a clue, not a forced binding: the validated decision may choose another known project.
    try await store.applyTriage(eventID: followup.id, decision: .init(action: .investigate, goal: "Inspect the other project", reason: "Explicit topic change identifies the other known project", repository: other))
    let child = try #require(await store.source(followup.id).taskID)
    #expect(try await store.agentSession(taskID: child)?.repository == other)
    #expect(try await store.messages(taskID: child).first?.body.contains("Slack background context (data, not authorization)") == true)
}

@Test func failedSlackBatchRollsBackRawContextCacheAsWellAsEvents() async throws {
    let root = try contextRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try await contextStore(root + "/state.sqlite")
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: nil, events: [])
    let invalid = SourceEvent(integration: "slack", sourceID: "T1:C1:1500", revision: "v1", associationKey: "slack:T1:C1:thread:1500", body: "Invalid", url: "", slackMessage: SlackMessage(timestamp: "1800", threadTimestamp: "1500", author: "U1", text: "Must not persist"))
    await #expect(throws: ManagerError.self) { try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 1, events: [contextEvent("1000", text: "Also must roll back"), invalid]) }
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 1, events: [contextEvent("2000", text: "New question")])
    let event = try #require(await store.claimTriageEvent())
    #expect(event.slackContext?.precedingMessages.isEmpty == true)
    #expect(try await store.sources().count == 1)
}

private actor MetadataSlack: SlackHTTPTransport {
    func get(_ request: URLRequest) -> SlackHTTPResponse {
        SlackHTTPResponse(data: Data(#"{"ok":true,"channels":[{"id":"C1","name":"todo","topic":{"value":"Todo CLI"},"purpose":{"value":"Work on the app"}}]}"#.utf8))
    }
}
@Test func slackDiscoveryRetainsChannelTopicAndPurpose() async throws {
    let conversations = try await SlackClient(token: "fixture", transport: MetadataSlack()).conversations()
    #expect(conversations.first?.topic == "Todo CLI")
    #expect(conversations.first?.purpose == "Work on the app")
}

@Test func preUpgradeSlackHistoryCanSupplyProjectCluesBeforeNextPoll() async throws {
    let root = try contextRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try await contextStore(root + "/state.sqlite")
    let old = SourceEvent(integration: "slack", sourceID: "T1:C1:1000", revision: "v1", associationKey: "slack:T1:C1:thread:1000", body: "We are discussing the todo list app", url: "")
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: nil, events: [old])
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 1, events: [contextEvent("2000", text: "How does it work?")])
    let event = try #require(await store.claimTriageEvent())
    #expect(event.slackContext?.precedingMessages.first?.text.contains("todo list app") == true)
}

@Test func oldProjectQuestionsGetOneContextReviewButNewAmbiguityQuestionsStayWaiting() async throws {
    let root = try contextRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try await contextStore(root + "/state.sqlite")
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: nil, events: [])
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 1, events: [contextEvent("2000", text: "How does storage work?")])
    let event = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: event.id, decision: .init(action: .clarify, reason: "Still two equally plausible projects", question: "Which project do you mean?"))
    try await store.reconcileSlackConversations(workspaceID: "T1", conversations: [SlackConversation(id: "C1", name: "general", isDM: false)])
    #expect(try await store.source(event.id).disposition == .waitingForUser)
    // Simulate an older question asked before routing context existed.
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [root + "/state.sqlite", "UPDATE event_context SET routing_context = NULL WHERE event_id = \(event.id);"]
    try sqlite.run(); sqlite.waitUntilExit()
    #expect(sqlite.terminationStatus == 0)
    try await store.reconcileSlackConversations(workspaceID: "T1", conversations: [SlackConversation(id: "C1", name: "general", isDM: false)])
    #expect(try await store.source(event.id).disposition == .pending)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: event.id, decision: .init(action: .clarify, reason: "Full context remains ambiguous", question: "Which project do you mean?"))
    try await store.reconcileSlackConversations(workspaceID: "T1", conversations: [SlackConversation(id: "C1", name: "general", isDM: false)])
    #expect(try await store.source(event.id).disposition == .waitingForUser)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_SLACK_CONTEXT"] == "1"))
func liveMasterUsesSlackContextAndStillClarifiesGenuineAmbiguity() async throws {
    let scenarios: [(String, String, String, String?, String?)] = [
        ("todo-app-dev", "Work on the todo CLI", "How does storage work?", nil, "todo-app"),
        ("general", "Team discussion", "How does storage work?", "We are working on the todo app CLI and its SQLite persistence.", "todo-app"),
        ("todo-app-dev", "Todo app discussion", "For the weather app, how is caching implemented?", "We previously discussed the todo app.", "weather-app"),
        ("general", "Several projects", "How does storage work?", "Both the todo app and the weather app have storage. We have not decided which project to discuss next.", nil),
    ]
    for (name, topic, question, preceding, expected) in scenarios {
        let root = try contextRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try await contextStore(root + "/state.sqlite")
        for project in ["todo-app", "weather-app"] {
            let path = root + "/" + project
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try await store.registerProject(repository: path)
        }
        try await store.reconcileSlackConversations(workspaceID: "T1", conversations: [SlackConversation(id: "C1", name: name, isDM: false, topic: topic)])
        try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: nil, events: preceding.map { [contextEvent("1000", text: $0)] } ?? [])
        try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 1, events: [contextEvent("2000", text: question)])
        let event = try #require(await store.claimTriageEvent())
        let decision = try await CodexMasterTriage(stateDirectory: root).decide(event: event, candidates: [])
        if let expected {
            #expect(decision.action == .investigate)
            #expect(decision.repository == root + "/" + expected)
        } else { #expect(decision.action == .clarify) }
    }
}

@Test func routingUsesLatestEditedHistoryRatherThanOldRevision() async throws {
    let root = try contextRoot()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try await contextStore(root + "/state.sqlite")
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: nil, events: [contextEvent("1000", text: "Old project context")])
    try await store.commitSlackPoll("slack:T1:C1", expectedGeneration: 1, events: [contextEvent("1000", text: "Corrected context: we are discussing the weather app", revision: "v2"), contextEvent("2000", text: "How does it work?")])
    let edited = try #require(await store.claimTriageEvent())
    try await store.ignoreSource(edited.id)
    let question = try #require(await store.claimTriageEvent())
    #expect(question.slackContext?.precedingMessages.count == 1)
    #expect(question.slackContext?.precedingMessages.first?.text.contains("weather app") == true)
    #expect(question.slackContext?.precedingMessages.first?.text.contains("Old project") == false)
}
