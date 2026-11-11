import Foundation
import TaskManagerCore
import TaskManagerPersistence
import Testing

private func activityRoot() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-activity-\(UUID())").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func clearingActivityPreservesTasksInboxesRepliesAttentionAndDeduplication() async throws {
    let root = try activityRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite", store = try Store(path: root + "/state.sqlite")
    let parent = try await store.createAgentTask(goal: "Existing work", repository: root, kind: .mock)
    try await store.transition(parent.id, to: .paused)
    let routed = try await store.injectSource(body: "Compatible update", repository: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: routed, decision: .init(action: .route, taskID: parent.id, reason: "Relevant follow-up"))
    let ignored = try await store.injectSource(body: "Thanks", repository: root)
    try await store.ignoreSource(ignored)
    let investigated = try await store.injectSource(body: "What changed?", repository: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: investigated, decision: .init(action: .investigate, goal: "Inspect changes", reason: "Pure question"))
    let child = try #require(await store.source(investigated).taskID)
    try await store.transition(child, to: .running)
    try await store.completeExploration(taskID: child, findings: "Verified", reply: "A reply that must remain in Needs you")
    let waiting = try await store.injectSource(body: "Which one?", repository: root)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: waiting, decision: .init(action: .clarify, reason: "Ambiguous", question: "Which task?"))
    let failed = try await store.injectSource(body: "Retry me", repository: root)
    let now = Date()
    for attempt in 0..<3 {
        _ = try await store.claimTriageEvent(now: now.addingTimeInterval(Double(attempt * 100)))
        try await store.failTriage(failed, error: "Fixture failure", now: now.addingTimeInterval(Double(attempt * 100)))
    }
    let triaging = try await store.injectSource(body: "Being reviewed", repository: root)
    _ = try await store.claimTriageEvent()
    let pending = try await store.injectSource(body: "New pending message", repository: root)
    #expect(try await store.clearIncomingActivity() == 3)
    #expect(try await store.clearIncomingActivity() == 0)
    #expect(Set(try await store.incomingActivity().map(\.id)) == [waiting, failed, triaging, pending])
    #expect(try await store.task(parent.id).status == .paused)
    #expect(try await store.messages(taskID: parent.id).count == 1)
    #expect(try await store.userActions().first?.status == "open")
    #expect(try await store.sourcesNeedingAttention().count == 2)
    #expect(try await store.taskInfo(parent.id).sources.contains { $0.id == routed })
    let reopened = try Store(path: path)
    #expect(try await reopened.incomingActivity().count == 4)
    let original = try await reopened.source(routed)
    let replay = SourceEvent(integration: original.integration, sourceID: original.sourceID, revision: original.revision, associationKey: original.associationKey, body: original.body, url: original.url)
    #expect(try await reopened.ingest([replay], repository: root) == 0)
    #expect(try await reopened.isVisibleInActivity(routed) == false)
    let edited = SourceEvent(integration: original.integration, sourceID: original.sourceID, revision: "edited", associationKey: original.associationKey, body: "New information", url: original.url)
    #expect(try await reopened.ingest([edited], repository: root) == 1)
    #expect(try await reopened.incomingActivity().count == 5)
    #expect(try await reopened.restoreIncomingActivity() == 3)
    #expect(try await reopened.sources().count == 8)
    #expect(try await reopened.incomingActivity().count == 8)
}

@Test func clearActivityIncludesOlderPagesAndAllowsRestoringOneSource() async throws {
    let root = try activityRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    var ids: [Int64] = []
    for index in 0..<125 {
        let id = try await store.injectSource(body: "Historical \(index)", repository: root)
        try await store.ignoreSource(id); ids.append(id)
    }
    #expect(try await store.incomingActivity().count == 100)
    #expect(try await store.clearIncomingActivity() == 125)
    #expect(try await store.incomingActivity().isEmpty)
    let id = try #require(ids.first)
    try await store.revealIncomingActivity(id)
    #expect(try await store.incomingActivity().map(\.id) == [id])
    try await store.hideIncomingActivity(id)
    #expect(try await store.incomingActivity().isEmpty)
    #expect(try await store.restoreIncomingActivity() == 125)
}

@Test func hidingCannotSuppressPendingWorkAndReconsideredMessagesBecomeVisible() async throws {
    let root = try activityRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let id = try await store.injectSource(body: "Needs triage", repository: root)
    await #expect(throws: ManagerError.self) { try await store.hideIncomingActivity(id) }
    try await store.ignoreSource(id)
    try await store.hideIncomingActivity(id)
    #expect(try await store.isVisibleInActivity(id) == false)
    try await store.unignoreSource(id)
    #expect(try await store.isVisibleInActivity(id))
    #expect(try await store.incomingActivity().first?.disposition == .pending)
}
