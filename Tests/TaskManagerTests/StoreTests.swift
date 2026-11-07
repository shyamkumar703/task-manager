import Foundation
import Testing
import TaskManagerCore
import TaskManagerPersistence

private func temporaryDatabase() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-manager-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("state.sqlite").path
}

@Test func questionsSurviveReopeningAndAnswersResumeOnlyTheirTask() async throws {
    let path = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
    let store = try Store(path: path)
    let first = try await store.createTask(goal: "Investigate feedback")
    let second = try await store.createTask(goal: "Independent task")
    try await store.transition(first.id, to: .running)
    try await store.transition(second.id, to: .running)
    let questionID = try await store.ask(taskID: first.id, prompt: "Which behavior?")
    let reopened = try Store(path: path)
    #expect(try await reopened.questions().map(\.id) == [questionID])
    #expect(try await reopened.task(second.id).status == .running)
    try await reopened.answer(questionID: questionID, text: "Preserve ordering")
    #expect(try await store.task(first.id).status == .queued)
    #expect(try await store.task(second.id).status == .running)
    #expect(try await store.messages(taskID: first.id, pendingOnly: true).count == 1)
    await #expect(throws: ManagerError.self) { try await store.answer(questionID: questionID, text: "Again") }
    #expect(try await store.messages(taskID: first.id).count == 1)
}

@Test func rejectedTransitionsAreAtomicAndPausedAnswersStayPaused() async throws {
    let store = try Store(path: ":memory:")
    let task = try await store.createTask(goal: "Task")
    let before = try await store.journal().count
    await #expect(throws: ManagerError.self) { try await store.ask(taskID: task.id, prompt: "Question") }
    #expect(try await store.task(task.id).status == .queued)
    #expect(try await store.questions().isEmpty)
    #expect(try await store.journal().count == before)
    try await store.transition(task.id, to: .running)
    let question = try await store.ask(taskID: task.id, prompt: "Question")
    try await store.transition(task.id, to: .paused)
    await #expect(throws: ManagerError.self) { try await store.transition(task.id, to: .queued) }
    try await store.resume(task.id)
    #expect(try await store.task(task.id).status == .waitingForUser)
    try await store.transition(task.id, to: .paused)
    try await store.answer(questionID: question, text: "Answer")
    #expect(try await store.task(task.id).status == .paused)
}

@Test func eventRetriesAreDeduplicatedAndEditsDeliveredOnce() async throws {
    let store = try Store(path: ":memory:")
    let key = "github:owner/repo:pr:1"
    let task = try await store.createTask(goal: "Handle PR", sourceKey: key)
    let original = SourceEvent(integration: "github", sourceID: "comment:1", revision: "v1", associationKey: key, body: "Fix validation", url: "https://github.com/owner/repo/pull/1")
    let edited = SourceEvent(integration: "github", sourceID: "comment:1", revision: "v2", associationKey: key, body: "Fix input validation", url: original.url)
    let unknown = SourceEvent(integration: "github", sourceID: "comment:2", revision: "v1", associationKey: "other-pr", body: "Investigate", url: original.url)
    #expect(try await store.ingest([original, original, edited, unknown]) == 3)
    #expect(try await store.ingest([original, edited]) == 0)
    #expect(try await store.routeKnownEvents() == 2)
    #expect(try await store.routeKnownEvents() == 0)
    #expect(try await store.pendingEventCount() == 1)
    let messages = try await store.messages(taskID: task.id)
    #expect(messages.count == 2)
    try await store.acknowledge(messageID: messages[0].id)
    try await store.acknowledge(messageID: messages[0].id)
    #expect(try await store.messages(taskID: task.id, pendingOnly: true).count == 1)
}

@Test func concurrentIngestionUsesDatabaseUniqueness() async throws {
    let path = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
    let first = try Store(path: path)
    let second = try Store(path: path)
    let event = SourceEvent(integration: "github", sourceID: "1", revision: "1", associationKey: "pr:1", body: "Feedback", url: "")
    async let a = first.ingest([event])
    async let b = second.ingest([event])
    let inserted = try await [a, b]
    #expect(inserted.reduce(0, +) == 1)
}

@Test func proposalDecisionsAreImmutableAndPersisted() async throws {
    let store = try Store(path: ":memory:")
    let task = try await store.createTask(goal: "Handle feedback")
    let id = try await store.proposeComment(taskID: task.id, target: "https://github.com/owner/repo/pull/1", body: "Verified locally", expectedHead: "abc123")
    #expect(try await store.proposals().first?.status == .pending)
    try await store.decide(proposalID: id, approve: true)
    await #expect(throws: ManagerError.self) { try await store.decide(proposalID: id, approve: false) }
    let proposal = try #require(await store.proposals().first)
    #expect(proposal.status == .approved)
    #expect(proposal.body == "Verified locally")
    #expect(proposal.expectedHead == "abc123")
    await #expect(throws: ManagerError.self) {
        try await store.proposeComment(taskID: task.id, target: "https://example.com/owner/repo/pull/1", body: "No", expectedHead: "abc")
    }
}

@Test func cancelledTasksKeepHistoryWithoutAcceptingNewWork() async throws {
    let store = try Store(path: ":memory:")
    let task = try await store.createTask(goal: "Investigate", sourceKey: "pr:1")
    try await store.transition(task.id, to: .running)
    let question = try await store.ask(taskID: task.id, prompt: "Need input")
    let proposal = try await store.proposeComment(taskID: task.id, target: "https://github.com/o/r/pull/1", body: "Reply", expectedHead: "abc")
    try await store.transition(task.id, to: .cancelled)
    #expect(try await store.questions().isEmpty)
    #expect(try await store.questions(pendingOnly: false).count == 1)
    await #expect(throws: ManagerError.self) { try await store.answer(questionID: question, text: "Too late") }
    await #expect(throws: ManagerError.self) { try await store.addMessage(taskID: task.id, body: "More work") }
    await #expect(throws: ManagerError.self) { try await store.decide(proposalID: proposal, approve: true) }
    try await store.ingest([SourceEvent(integration: "github", sourceID: "1", revision: "1", associationKey: "pr:1", body: "Feedback", url: "")])
    #expect(try await store.routeKnownEvents() == 0)
    #expect(try await store.pendingEventCount() == 1)
}

@Test func invalidBatchesAndDuplicateTaskAssociationsLeaveNoPartialJournal() async throws {
    let store = try Store(path: ":memory:")
    _ = try await store.createTask(goal: "Existing", sourceKey: "pr:1")
    let before = try await store.journal().count
    await #expect(throws: ManagerError.self) { try await store.createTask(goal: "Duplicate", sourceKey: "pr:1") }
    #expect(try await store.tasks().count == 1)
    #expect(try await store.journal().count == before)
    let good = SourceEvent(integration: "github", sourceID: "1", revision: "1", associationKey: "pr:1", body: "Valid", url: "")
    let bad = SourceEvent(integration: "github", sourceID: "2", revision: "1", associationKey: "pr:1", body: "\0invalid", url: "")
    await #expect(throws: ManagerError.self) { try await store.ingest([good, bad]) }
    #expect(try await store.pendingEventCount() == 0)
    #expect(try await store.journal().count == before)
}
