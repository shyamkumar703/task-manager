import Foundation
import TaskManagerCore
import TaskManagerPersistence
@testable import TaskManagerTUI
import Testing

@Test func taskInfoIncludesDurableOriginAndScopedHistoryBeyondRecentActivity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-info-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let initial = try await store.injectSource(body: "Build title validation", repository: root, workerKind: .mock)
    _ = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: initial, decision: .init(action: .clarify, reason: "Needs requirements", question: "Which titles?"))
    try await store.answerSource(eventID: initial, text: "Reject whitespace")
    _ = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: initial, decision: .init(action: .create, goal: "Validate titles", reason: "New validation request"))
    let taskID = try #require(await store.source(initial).taskID)
    let initialMessage = try #require(await store.source(initial).messageID)
    try await store.acknowledge(messageID: initialMessage)
    let followup = try await store.injectSource(body: "Also reject tabs", repository: root)
    _ = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: followup, decision: .init(action: .route, taskID: taskID, reason: "Additional validation case"))
    let conflict = try await store.injectSource(body: "Actually accept every title", repository: root)
    _ = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: conflict, decision: .init(action: .conflict, taskID: taskID, reason: "Contradicts validation", question: "Should validation be removed?"))
    let other = try await store.createTask(goal: "Unrelated")
    try await store.record(taskID: other.id, kind: "unrelated.decision", detail: "Must not appear")
    for index in 0..<110 { _ = try await store.injectSource(body: "Unrelated message \(index)", repository: root) }
    #expect(try await store.sources().allSatisfy { $0.id != initial })
    let reopened = try Store(path: root + "/state.sqlite")
    let info = try await reopened.taskInfo(taskID)
    #expect(info.sources.map(\.id) == [initial, followup, conflict])
    #expect(info.journal.contains { $0.kind == "triage.answered" && $0.detail == String(initial) })
    #expect(info.journal.contains { $0.kind == "triage.clarify" && $0.detail.contains("Contradicts validation") })
    #expect(!info.journal.contains { $0.taskID == other.id })
    #expect(info.journal.map(\.id) == info.journal.map(\.id).sorted())
    let sections = TaskInfoPresentation.sections(info)
    #expect(sections.first?.text.contains("Created from Mock") == true)
    #expect(sections.first?.text.contains("New validation request") == true)
    #expect(sections.contains { $0.text.contains("Accepted by child") })
    #expect(sections.contains { $0.text.contains("Queued; not yet accepted") })
    #expect(sections.contains { $0.text.contains("Not forwarded (waitingForUser)") })
    let investigation = try #require(await reopened.investigateSource(initial))
    let investigationInfo = try await reopened.taskInfo(investigation)
    #expect(TaskInfoPresentation.sections(investigationInfo).first?.text.contains("Independent investigation requested by user") == true)
    let originalHistory = try await reopened.taskInfo(taskID)
    #expect(originalHistory.sources.contains { $0.id == initial && $0.taskID == investigation })
    #expect(TaskInfoPresentation.sections(originalHistory).contains { $0.text.contains("Previously linked; now associated with another child") })
}

@Test func taskInfoShowsLocalMessagesQuestionsAndAnswersWithoutInventingDecisions() async throws {
    let store = try Store(path: ":memory:")
    let task = try await store.createTask(goal: "Local task")
    try await store.transition(task.id, to: .running)
    let question = try await store.ask(taskID: task.id, prompt: "Which approach?")
    let pending = try await store.taskInfo(task.id)
    #expect(TaskInfoPresentation.sections(pending).contains { $0.title == "QUESTION · AWAITING ANSWER" && $0.text.contains("Which approach?") })
    try await store.answer(questionID: question, text: "Use SQLite")
    let info = try await store.taskInfo(task.id)
    let sections = TaskInfoPresentation.sections(info)
    #expect(info.sources.isEmpty)
    #expect(sections.first?.text.contains("Created locally") == true)
    #expect(sections.contains { $0.title == "QUESTION · ANSWERED" && $0.text.contains("Use SQLite") })
    #expect(sections.contains { $0.title == "TASK DETAILS" && $0.text.contains(task.id) })
    #expect(sections.contains { $0.title == "TASK MESSAGE · QUEUED" && $0.text.contains("Use SQLite") })
    #expect(sections.contains { $0.title.hasPrefix("DECISION / TRANSACTION HISTORY") && $0.text.contains("private model reasoning is not recorded") })
}
