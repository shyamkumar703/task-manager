import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import Testing

@Test func existingTenSecondWorkspaceConstraintMigratesWithoutLosingSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("interval-migration-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite", store = try Store(path: root + "/state.sqlite")
    try await store.ensureSlackWorkspace(id: "T1", name: "Personal", userID: "U1")
    try await store.setSlackWorkspaceInterval("T1", seconds: 300)
    try await store.failSlackDiscovery("T1", error: "Fixture failure")
    let before = try #require(await store.slackWorkspaces().first)
    let sql = """
    BEGIN;
    ALTER TABLE slack_workspaces RENAME TO workspace_fixture;
    CREATE TABLE slack_workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, user_id TEXT NOT NULL, next_discovery REAL NOT NULL DEFAULT 0, last_success REAL, last_error TEXT, failures INTEGER NOT NULL DEFAULT 0, poll_interval_seconds INTEGER NOT NULL DEFAULT 60 CHECK(poll_interval_seconds BETWEEN 10 AND 86400));
    INSERT INTO slack_workspaces SELECT * FROM workspace_fixture;
    DROP TABLE workspace_fixture;
    PRAGMA user_version = 16;
    COMMIT;
    """
    let runner = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/sqlite3"))
    #expect(try await runner.run(arguments: [path, sql]).exitCode == 0)
    let reopened = try Store(path: path)
    let after = try #require(await reopened.slackWorkspaces().first)
    #expect(after.name == before.name && after.userID == before.userID)
    #expect(after.intervalSeconds == 300 && after.nextDiscovery == before.nextDiscovery)
    #expect(after.lastError == before.lastError && after.failures == before.failures)
    try await reopened.setSlackWorkspaceInterval("T1", seconds: 1)
    #expect(try await reopened.slackWorkspaces().first?.intervalSeconds == 1)
}

@Test func workspacePollingIntervalPersistsAndNewChannelsInheritWhileOverridesSurvive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("connection-intervals-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/state.sqlite", store = try Store(path: root + "/state.sqlite")
    for workspace in ["T1", "T2"] { try await store.ensureSlackWorkspace(id: workspace, name: workspace, userID: "U1") }
    try await store.reconcileSlackConversations(workspaceID: "T1", conversations: [.init(id: "C1", name: "first", isDM: false), .init(id: "C2", name: "second", isDM: false)])
    try await store.reconcileSlackConversations(workspaceID: "T2", conversations: [.init(id: "C1", name: "other", isDM: false)])
    try await store.setSlackSourceEnabled("slack:T1:C2", enabled: false)
    try await store.setSlackWorkspaceInterval("T1", seconds: 300)
    #expect(try await store.slackSources().filter { $0.workspaceID == "T1" }.allSatisfy { $0.intervalSeconds == 300 && $0.nextPoll == 0 })
    #expect(try await store.slackSources().first { $0.id == "slack:T1:C2" }?.enabled == false)
    #expect(try await store.slackSources().first { $0.workspaceID == "T2" }?.intervalSeconds == 60)
    try await store.setSlackSourceInterval("slack:T1:C1", seconds: 30)
    try await store.reconcileSlackConversations(workspaceID: "T1", conversations: [.init(id: "C1", name: "renamed", isDM: false), .init(id: "C2", name: "second", isDM: false), .init(id: "C3", name: "new", isDM: false)])
    #expect(try await store.slackSources().first { $0.id == "slack:T1:C1" }?.intervalSeconds == 30)
    #expect(try await store.slackSources().first { $0.id == "slack:T1:C3" }?.intervalSeconds == 300)
    let reopened = try Store(path: path)
    try await reopened.ensureSlackWorkspace(id: "T1", name: "New name", userID: "U1")
    #expect(try await reopened.slackWorkspaces().first { $0.id == "T1" }?.intervalSeconds == 300)
    await #expect(throws: ManagerError.self) { try await reopened.setSlackWorkspaceInterval("T1", seconds: 0) }
    await #expect(throws: ManagerError.self) { try await reopened.setSlackWorkspaceInterval("T1", seconds: 86401) }
    await #expect(throws: ManagerError.self) { try await reopened.setSlackWorkspaceInterval("missing", seconds: 120) }
    #expect(try await reopened.slackWorkspaces().first { $0.id == "T1" }?.intervalSeconds == 300)
    try await reopened.setSlackWorkspaceInterval("T1", seconds: 1)
    #expect(try await reopened.slackSources().filter { $0.workspaceID == "T1" }.allSatisfy { $0.intervalSeconds == 1 })
    try await reopened.setSlackSourceInterval("slack:T1:C1", seconds: 1)
    let github = try await reopened.addGitHubSource(repository: "o/r", localRepository: root, author: "me", intervalSeconds: 1)
    try await reopened.setGitHubSourceInterval(github, seconds: 1)
    #expect(try await reopened.gitHubSources().first?.intervalSeconds == 1)
    _ = try await reopened.addSlackSource(workspaceID: "T2", workspaceName: "T2", userID: "U1", channelID: "C2", channelName: "fast", intervalSeconds: 1)
    await #expect(throws: ManagerError.self) { try await reopened.setSlackSourceInterval("slack:T1:C1", seconds: 0) }
    await #expect(throws: ManagerError.self) { try await reopened.setGitHubSourceInterval(github, seconds: 0) }
    try await reopened.reconcileSlackConversations(workspaceID: "T1", conversations: [.init(id: "C4", name: "new fast channel", isDM: false)])
    #expect(try await reopened.slackSources().first { $0.id == "slack:T1:C4" }?.intervalSeconds == 1)
}
