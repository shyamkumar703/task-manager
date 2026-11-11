import Foundation
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private func refinementRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("requirement-refinement-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

@Test func triageContextIdentifiesAssistantChoicesSeparatelyFromUserInstructions() async throws {
    let root = try refinementRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: ":memory:")
    let task = try await store.createAgentTask(goal: "Create a search command that searches todos", repository: root, kind: .mock)
    _ = try await store.addMessage(taskID: task.id, body: "Search todo titles; I have no preference about case matching.")
    try await store.writeOutput(taskID: task.id, itemID: "choice", kind: "assistant", text: "I chose case-sensitive search and added tests for that behavior.")
    let candidate = try #require(await store.triageCandidates(repository: root).first)
    #expect(candidate.recentContext.contains { $0.hasPrefix("Assistant report (not user approval") && $0.contains("case-sensitive") })
    #expect(candidate.recentContext.contains { $0.hasPrefix("Task inbox") && $0.contains("no preference") })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_REFINEMENT"] == "1"))
func liveTriageRoutesChangesToAgentDefaultsButHoldsExplicitRequirementConflicts() async throws {
    let root = try refinementRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    for integration in ["slack", "github"] {
        let store = try Store(path: ":memory:")
        let task = try await store.createAgentTask(goal: "Create a search command that searches todos", repository: root, kind: .mock)
        try await store.writeOutput(taskID: task.id, itemID: "implementation", kind: "assistant", text: "I chose case-sensitive matching by default. I implemented it, documented the behavior, and added tests asserting that uppercase queries do not match lowercase titles.")
        try await store.transition(task.id, to: .running); try await store.transition(task.id, to: .completed)
        try await store.ingest([.init(integration: integration, sourceID: "feedback:1", revision: "1", associationKey: "search-feedback", body: "Can we make the todo search command case insensitive?", url: "https://example.invalid/feedback")], repository: root)
        let event = try #require(await store.claimTriageEvent())
        let decision = try await CodexMasterTriage(stateDirectory: root).decide(event: event, candidates: store.triageCandidates(repository: root))
        #expect(decision.action == .route)
        #expect(decision.taskID == task.id)
        #expect(decision.question == nil)
        try await store.applyTriage(eventID: event.id, decision: decision)
        #expect(try await store.task(task.id).status == .queued)
        #expect(try await store.source(event.id).disposition == .routed)
        #expect(try await store.sourcesNeedingAttention().isEmpty)
    }
    let store = try Store(path: ":memory:")
    let task = try await store.createAgentTask(goal: "Create a search command that searches todos. Matching MUST be case sensitive; preserve case-sensitive matching.", repository: root, kind: .mock)
    let id = try await store.injectSource(body: "Can we make the todo search command case insensitive?", repository: root)
    let event = try #require(await store.claimTriageEvent())
    let master = CodexMasterTriage(stateDirectory: root)
    let conflict = try await master.decide(event: event, candidates: store.triageCandidates(repository: root))
    #expect(conflict.action == .conflict)
    #expect(conflict.taskID == task.id)
    try await store.applyTriage(eventID: id, decision: conflict)
    #expect(try await store.source(id).disposition == .waitingForUser)
    try await store.answerSource(eventID: id, text: "Change the requirement: case-insensitive matching is now approved. Apply the feedback.")
    let clarified = try #require(await store.claimTriageEvent())
    let resolved = try await master.decide(event: clarified, candidates: store.triageCandidates(repository: root))
    #expect(resolved.action == .route)
    #expect(resolved.taskID == task.id)
    #expect(resolved.question == nil)
}
