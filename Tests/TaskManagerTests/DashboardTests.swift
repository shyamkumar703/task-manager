import Foundation
import TaskManagerCore
import TaskManagerPersistence
@testable import TaskManagerTUI
import Testing

private func dashboardValue<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
}
private func dashboardTask(_ id: String, status: String, archived: Bool = false) throws -> ManagedTask {
    var value: [String: Any] = ["id": id, "goal": "Task " + id, "status": status, "createdAt": "2026-11-07", "updatedAt": "2026-11-07"]
    if archived { value["archivedAt"] = "2026-11-08" }
    return try dashboardValue(ManagedTask.self, value)
}

@Test func dashboardCombinesBlockingQuestionsRepliesApprovalsAndFailuresWithoutStaleChildQuestions() throws {
    let waiting = try dashboardTask("waiting", status: "waitingForUser")
    let cancelled = try dashboardTask("cancelled", status: "cancelled")
    let archived = try dashboardTask("archived", status: "paused", archived: true)
    let failed = try dashboardTask("failed", status: "failed")
    let questions = try [waiting, cancelled, archived].map { try dashboardValue(Question.self, ["id": "question-" + $0.id, "taskID": $0.id, "prompt": "Which acceptance criterion?"]) }
    let source = try dashboardValue(IncomingSource.self, ["id": 1, "integration": "slack", "sourceID": "T:C:1", "revision": "v1", "associationKey": "thread", "body": "How does it work?", "url": "slack://source", "repository": "", "workerKind": "codex", "disposition": "waitingForUser", "question": "Which project?", "attempts": 1])
    let reply = try dashboardValue(UserAction.self, ["id": "reply", "taskID": waiting.id, "sourceEventID": 1, "target": "slack://source", "body": "Suggested response", "context": "Evidence", "status": "open"])
    let done = try dashboardValue(UserAction.self, ["id": "done", "taskID": waiting.id, "sourceEventID": 1, "target": "slack://source", "body": "Already handled", "context": "Evidence", "status": "done"])
    let proposals = try [waiting, cancelled].map { try dashboardValue(ActionProposal.self, ["id": "proposal-" + $0.id, "taskID": $0.id, "kind": "github.comment", "target": "https://github.com/o/r/pull/1", "body": "Proposed text", "expectedHead": "abc", "status": "pending"]) }
    let items = DashboardModel.attention(tasks: [waiting, cancelled, archived, failed], questions: questions, sources: [source], actions: [reply, done], proposals: proposals, slack: [], workspaces: [], github: [])
    #expect(items.map(\.id) == ["source:1", "question:question-waiting", "approval:proposal-waiting", "reply:reply", "task:failed"])
    #expect(items.first?.title == "Which project?")
}

@Test func dashboardSurfacesAuthenticationFailuresImmediatelyButLetsTransientNetworkRetriesRun() throws {
    func source(_ id: String, error: String, failures: Int, enabled: Bool = true) throws -> SlackSource {
        try dashboardValue(SlackSource.self, ["id": id, "workspaceID": "T", "workspaceName": "Test", "userID": "U", "channelID": "C", "channelName": id, "repository": "", "intervalSeconds": 60, "enabled": enabled, "nextPoll": 0, "lastError": error, "failures": failures])
    }
    let sources = try [source("auth", error: "missing_scope", failures: 1), source("retrying", error: "network timeout", failures: 1), source("persistent", error: "network timeout", failures: 3), source("paused", error: "missing_scope", failures: 5, enabled: false)]
    let items = DashboardModel.attention(tasks: [], questions: [], sources: [], actions: [], proposals: [], slack: sources, workspaces: [], github: [])
    #expect(items.map(\.id) == ["slack:auth", "slack:persistent"])
}

@Test func dashboardKeepsRunningWorkAheadOfCompletedTasksAndPreservesSelectionOnNewAttention() throws {
    let tasks = try [dashboardTask("completed", status: "completed"), dashboardTask("running", status: "running"), dashboardTask("queued", status: "queued"), dashboardTask("paused", status: "paused")]
    #expect(DashboardModel.work(tasks).map(\.id) == ["running", "queued", "paused", "completed"])
    #expect(DashboardModel.preservedSelection("reply", old: ["question", "reply"], new: ["new-question", "question", "reply"]) == "reply")
    #expect(DashboardModel.preservedSelection("question", old: ["question", "reply"], new: ["reply"]) == "reply")
    #expect(DashboardModel.preservedSelection("reply", old: ["reply"], new: []) == nil)
}

@Test func vimPaneNavigationAndScrollingDoNotMoveListSelectionOrTriggerActions() {
    var navigation = DashboardNavigation()
    #expect(navigation.handle(106, dashboard: true) == .move(1))
    #expect(navigation.handle(23, dashboard: true) == .consumed)
    #expect(navigation.handle(108, dashboard: true) == .consumed)
    #expect(navigation.focus == .detail)
    navigation.viewport.update(count: 100, height: 20)
    #expect(navigation.handle(106, dashboard: true) == .consumed)
    #expect(navigation.viewport.offset == 1)
    #expect(navigation.handle(4, dashboard: true) == .consumed)
    #expect(navigation.viewport.offset == 11)
    #expect(navigation.handle(21, dashboard: true) == .consumed)
    #expect(navigation.viewport.offset == 1)
    _ = navigation.handle(23, dashboard: true); _ = navigation.handle(104, dashboard: true)
    #expect(navigation.focus == .attention)
    _ = navigation.handle(23, dashboard: true); _ = navigation.handle(106, dashboard: true)
    #expect(navigation.focus == .work)
    #expect(navigation.detailSource == .work)
    _ = navigation.handle(23, dashboard: true); _ = navigation.handle(107, dashboard: true)
    #expect(navigation.focus == .attention)
    // An unrecognized Ctrl-W sequence is consumed instead of invoking an action such as x.
    _ = navigation.handle(23, dashboard: true)
    #expect(navigation.handle(120, dashboard: true) == .consumed)
    #expect(navigation.handle(120, dashboard: true) == nil)
}

@Test func vimJumpAndViewportFollowTailSurviveResizeAndNewOutput() {
    var navigation = DashboardNavigation()
    _ = navigation.handle(103, dashboard: true)
    #expect(navigation.handle(103, dashboard: true) == .first)
    #expect(navigation.handle(71, dashboard: true) == .last)
    navigation.sidebar(.work, task: true); _ = navigation.handle(108, dashboard: true)
    navigation.viewport.update(count: 100, height: 20)
    #expect(navigation.viewport.offset == 80)
    _ = navigation.handle(107, dashboard: true)
    navigation.viewport.update(count: 110, height: 20)
    #expect(navigation.viewport.offset == 79) // Reading older output is not interrupted.
    _ = navigation.handle(71, dashboard: true)
    #expect(navigation.viewport.offset == 90)
    navigation.viewport.update(count: 110, height: 30)
    #expect(navigation.viewport.offset == 80)
    _ = navigation.handle(103, dashboard: true); _ = navigation.handle(103, dashboard: true)
    #expect(navigation.viewport.offset == 0)
}

@Test func oldSourceClarificationsStayInAttentionBeyondRecentActivityLimitAndRejectStaleQuestionText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("state.sqlite").path)
    let id = try await store.injectSource(body: "What project?", repository: root.path)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: id, decision: .init(action: .clarify, reason: "Ambiguous project", question: "Which project should I use?"))
    for index in 0..<105 {
        let next = try await store.injectSource(body: "Chatter \(index)", repository: root.path)
        _ = try await store.claimTriageEvent()
        try await store.applyTriage(eventID: next, decision: .init(action: .ignore, reason: "Chatter"))
    }
    #expect(try await store.sources().contains { $0.id == id } == false)
    #expect(try await store.sourcesNeedingAttention().map(\.id) == [id])
    await #expect(throws: ManagerError.self) { try await store.answerSource(eventID: id, text: "Project A", expectedQuestion: "A different question") }
    #expect(try await store.source(id).disposition == .waitingForUser)
    try await store.answerSource(eventID: id, text: "Project A", expectedQuestion: "Which project should I use?")
    #expect(try await store.sourcesNeedingAttention().isEmpty)
}

@Test func vimPageMotionsRespectTheFocusedPane() {
    var navigation = DashboardNavigation()
    navigation.listCapacities[.attention] = 8
    #expect(navigation.handle(4, dashboard: true) == .move(4))
    #expect(navigation.focus == .attention)
    #expect(navigation.handle(2, dashboard: true) == .move(-8))
    navigation.sidebar(.work)
    navigation.listCapacities[.work] = 6
    #expect(navigation.handle(21, dashboard: true) == .move(-3))
    #expect(navigation.focus == .work)
    _ = navigation.handle(108, dashboard: true)
    navigation.viewport.update(count: 100, height: 20)
    #expect(navigation.handle(4, dashboard: true) == .consumed)
    #expect(navigation.viewport.offset == 10)
}
