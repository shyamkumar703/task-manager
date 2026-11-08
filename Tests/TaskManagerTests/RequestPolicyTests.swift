import CodexTransport
import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private struct StatusEvidenceAPI: GitHubHTTPTransport {
    func get(_ request: URLRequest) throws -> HTTPResponse {
        let path = request.url!.path
        let json: String
        if path == "/repos/o/r/pulls" {
            if request.url?.query?.contains("state=closed") == true { json = "[]" }
            else { json = #"[{"number":3,"title":"Add Swift todo CLI with remove command","user":{"login":"o"},"head":{"ref":"legacy-cli","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},{"number":4,"title":"Add due dates and colored listing","user":{"login":"o"},"head":{"ref":"due-dates","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},{"number":5,"title":"Add remove subcommand for deleting todos","user":{"login":"o"},"head":{"ref":"feature-remove","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]"# }
        } else if path == "/repos/o/r/pulls/5" {
            json = #"{"number":5,"title":"Remove command","user":{"login":"o"},"head":{"ref":"feature-remove","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","repo":{"full_name":"o/r"}},"state":"closed","merged":true,"merged_at":"2026-11-08T12:00:00Z","html_url":"https://github.com/o/r/pull/5"}"#
        } else if path.hasSuffix("/reviews") {
            json = #"[{"id":1,"body":"","state":"APPROVED","html_url":"https://github.com/o/r/pull/5#review-1","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]"#
        } else if path.hasSuffix("/check-runs") {
            json = #"{"total_count":1,"check_runs":[{"name":"command-tests","status":"completed","conclusion":"success","html_url":"https://github.com/o/r/actions/runs/1"}]}"#
        } else if path.hasSuffix("/comments") { json = "[]" }
        else { throw ManagerError.invalid("Unexpected endpoint \(path)") }
        return HTTPResponse(data: Data(json.utf8), status: 200)
    }
}
private actor EvidenceAgent: AgentConnection {
    nonisolated let events: AsyncStream<CodexClient.Event>
    let continuation: AsyncStream<CodexClient.Event>.Continuation
    var input: JSONValue?
    init() { let pair = AsyncStream<CodexClient.Event>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func connect() {}
    func stop() { continuation.finish() }
    func request(_ method: String, params: JSONValue) -> JSONValue {
        if method == "thread/start" { return .object(["thread": .object(["id": .string("status-thread")])]) }
        if method == "turn/start" {
            input = params
            continuation.yield(.init(method: "item/completed", params: .object(["threadId": .string("status-thread"), "item": .object(["id": .string("result"), "type": .string("agentMessage"), "text": .string(#"{"status":"completed","text":"Live GitHub evidence checked.","reply":"PR #5 is merged and command-tests succeeded."}"#)])])))
            continuation.yield(.init(method: "turn/completed", params: .object(["threadId": .string("status-thread"), "turn": .object(["status": .string("completed")])])))
            return .object(["turn": .object(["id": .string("status-turn")])])
        }
        return .object([:])
    }
}
private func policyGit(_ args: [String]) async throws -> String {
    let result = try await GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git")).run(arguments: args)
    guard result.exitCode == 0 else { throw ManagerError.invalid("Fixture git command failed") }
    return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
private func policyRepository() async throws -> (String, String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("request-policy-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let repository = root + "/repo"
    try await policyGit(["init", "-b", "main", repository])
    try await policyGit(["-C", repository, "config", "user.name", "Test"])
    try await policyGit(["-C", repository, "config", "user.email", "test@example.invalid"])
    try await policyGit(["-C", repository, "commit", "--allow-empty", "-m", "Initial"])
    try await policyGit(["-C", repository, "remote", "add", "origin", "https://github.com/o/r.git"])
    return (root, repository)
}

@Test func barePRStatusUsesLiveEvidenceWithoutRequiringPRCommitLocally() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "where are we with the delete command work", repository: repo)
    let source = try #require(await store.claimTriageEvent())
    let resolver = GitHubContextResolver(client: try GitHubClient(transport: StatusEvidenceAPI()))
    let context = try #require(await resolver.resolve(source: source, candidates: [], includeEvidence: true, selectedPR: 5))
    #expect(context.pullRequest == 5)
    #expect(context.liveEvidence?.contains("Merged: true") == true)
    #expect(context.liveEvidence?.contains("APPROVED") == true)
    #expect(context.liveEvidence?.contains("command-tests: completed, success") == true)
    try await store.applyTriage(eventID: id, decision: .init(action: .investigate, goal: "Check PR #5 status", reason: "Status question", inspectionScope: "status", pullRequestNumber: 5))
    let taskID = try #require(await store.source(id).taskID)
    for index in 0..<210 { try await store.writeOutput(taskID: taskID, itemID: "old-\(index)", kind: "system", text: "Old transcript entry") }
    let agent = EvidenceAgent()
    let coordinator = Coordinator(store: store, stateDirectory: root, githubResolver: resolver, factory: { agent })
    try await coordinator.tick()
    for _ in 0..<400 {
        if try await store.task(taskID).status == .completed { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await store.task(taskID).status == .completed)
    #expect(try await store.agentSession(taskID: taskID)?.baseRef == "github:o/r:pr:5")
    #expect(try await store.outputs(taskID: taskID).contains { $0.itemID == "github-evidence" && $0.text.contains("Merged: true") })
    #expect(try await store.userActions().first?.body.contains("PR #5 is merged") == true)
    let input = try #require(await agent.input)
    let prompt = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    #expect(prompt.contains("Merged: true") && prompt.contains("command-tests"))
    await coordinator.shutdown()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_REQUESTED_PUSH"] == "1"))
func liveWorkerHonorsExplicitPushRequestAgainstLocalBareRemote() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let remote = root + "/remote.git"
    try await policyGit(["init", "--bare", remote])
    try await policyGit(["-C", repo, "remote", "set-url", "origin", remote])
    try await policyGit(["-C", repo, "push", "origin", "main"])
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Create requested.txt containing requested push verified, commit that file, and push this task's branch to origin using git push --set-upstream origin HEAD. This is an explicit request to commit and push. The remote is a local bare test repository; do not create a PR or send messages. Verify the remote branch, then return a completed outcome.", repository: repo, kind: .codex)
    let coordinator = Coordinator(store: store, stateDirectory: root)
    do {
        try await coordinator.tick()
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            if try await store.task(task.id).status != .running { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await store.task(task.id).status == .completed)
        let remoteSHA = try await policyGit(["--git-dir=" + remote, "rev-parse", "refs/heads/task-manager/" + task.id])
        let workspace = try #require(await store.agentSession(taskID: task.id)?.workspace)
        #expect(try await policyGit(["-C", workspace, "rev-parse", "HEAD"]) == remoteSHA)
        #expect(try await policyGit(["--git-dir=" + remote, "show", remoteSHA + ":requested.txt"]).contains("requested push verified"))
        await coordinator.shutdown()
    } catch { await coordinator.shutdown(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_REQUEST_POLICY"] == "1"))
func livePRStatusAnswerUsesRemoteEvidenceWithoutLocalHead() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "What is the status of PR #5? Is it merged, what is its review status, and did command-tests pass?", repository: repo)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: id, decision: .init(action: .investigate, goal: "Check current PR #5 merge, review, and CI status using live GitHub evidence", reason: "Status request", inspectionScope: "status"))
    let taskID = try #require(await store.source(id).taskID)
    let resolver = GitHubContextResolver(client: try GitHubClient(transport: StatusEvidenceAPI()))
    let coordinator = Coordinator(store: store, stateDirectory: root, githubResolver: resolver)
    do {
        try await coordinator.tick()
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while ContinuousClock.now < deadline {
            if try await store.task(taskID).status != .running { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await store.task(taskID).status == .completed)
        let reply = try #require(await store.userActions().first?.body).lowercased()
        #expect(reply.contains("merged"))
        #expect(reply.contains("approved"))
        #expect(reply.contains("command-tests"))
        #expect(!reply.contains("can’t verify") && !reply.contains("cannot verify") && !reply.contains("can't verify"))
        await coordinator.shutdown()
    } catch { await coordinator.shutdown(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_REQUEST_POLICY"] == "1"))
func liveMasterTreatsCanYouPushAsAnActionRequest() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Implement todo remove command", repository: repo, kind: .mock)
    try await store.transition(task.id, to: .running); try await store.transition(task.id, to: .completed)
    let id = try await store.injectSource(body: "Can you push the changes for PR #5 now?", repository: repo)
    _ = try await store.claimTriageEvent()
    let event = try await store.recordGitHubContext(eventID: id, context: .init(repository: "o/r", pullRequest: 5, headBranch: "task-manager/" + task.id, headSHA: String(repeating: "a", count: 40), headRepository: "o/r", owningTaskID: task.id))
    let decision = try await CodexMasterTriage(stateDirectory: root).decide(event: event, candidates: store.triageCandidates(repository: repo))
    #expect(decision.action == .route)
    #expect(decision.taskID == task.id)
}

@Test func PRMentionOnlyInInvestigationGoalStillTriggersAuthenticatedLookup() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "where are we with the delete command work", repository: repo)
    let source = try await store.source(id)
    let resolver = GitHubContextResolver(client: try GitHubClient(transport: StatusEvidenceAPI()))
    let context = try #require(await resolver.resolve(source: source, candidates: [], includeEvidence: true, investigationGoal: "Determine the current live status of deletion PR #5, including review fixes, checks, and merge state"))
    #expect(context.pullRequest == 5)
    #expect(context.liveEvidence?.contains("Merged: true") == true)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_REQUEST_POLICY"] == "1"))
func liveMasterPassesPRFromTaskHistoryIntoGenericStatusInvestigation() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let owner = try await store.createAgentTask(goal: "Implement todo remove command", repository: repo, kind: .mock)
    try await store.transition(owner.id, to: .running); try await store.transition(owner.id, to: .completed)
    try await store.writeOutput(taskID: owner.id, itemID: "previous-result", kind: "assistant", text: "Deletion work is in PR #5: https://github.com/o/r/pull/5. The accepted command is todo remove <id>, with no delete alias.")
    _ = try await store.injectSource(body: "where are we with the delete command work", repository: repo)
    let event = try #require(await store.claimTriageEvent())
    let decision = try await CodexMasterTriage(stateDirectory: root).decide(event: event, candidates: store.triageCandidates(repository: repo))
    #expect(decision.action == .investigate)
    #expect(decision.inspectionScope == "status")
    #expect(decision.pullRequestNumber == 5)
}

private actor DiscoverySelector: PRSelecting {
    let choice: Int?
    var calls = 0
    init(choice: Int?) { self.choice = choice }
    func select(source: IncomingSource, goal: String?, tasks: [TriageCandidate], pulls: [GitHubPullRequest]) -> PRSelection {
        calls += 1
        #expect(!source.body.contains("#5") && !(goal ?? "").contains("#5"))
        #expect(pulls.map(\.number) == [3, 4, 5])
        return PRSelection(number: choice, reason: choice == nil ? "Several candidates remain equally plausible" : "The deletion task's feature-remove branch matches the PR head")
    }
}

@Test func genericStatusDiscoversOpenPRBeforeAskingAndUsesArchivedTaskHistory() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let owner = try await store.createAgentTask(goal: "Add support for deleting todos", repository: repo, kind: .mock)
    try await store.archive(owner.id)
    let id = try await store.injectSource(body: "where are we with the delete command work", repository: repo)
    _ = try await store.claimTriageEvent()
    try await store.applyTriage(eventID: id, decision: .init(action: .investigate, goal: "Determine the current status of the todo deletion work using fresh GitHub evidence", reason: "Status request", inspectionScope: "status"))
    let taskID = try #require(await store.source(id).taskID)
    let selector = DiscoverySelector(choice: 5)
    let resolver = GitHubContextResolver(client: try GitHubClient(transport: StatusEvidenceAPI()), selector: selector)
    let agent = EvidenceAgent()
    let coordinator = Coordinator(store: store, stateDirectory: root, githubResolver: resolver, factory: { agent })
    try await coordinator.tick()
    for _ in 0..<400 {
        if try await store.task(taskID).status == .completed { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await store.task(taskID).status == .completed)
    #expect(try await store.questions().isEmpty)
    #expect(await selector.calls == 1)
    #expect(try await store.source(id).githubContext?.pullRequest == 5)
    #expect(try await store.journal().contains { $0.taskID == taskID && $0.kind == "exploration.github.discovered" })
    #expect(try await store.triageCandidates(repository: repo).allSatisfy { $0.id != owner.id })
    #expect(try await store.triageCandidates(repository: repo, includeArchived: true).contains { $0.id == owner.id })
    await coordinator.shutdown()
}

@Test func ambiguousDiscoveryExplainsWhatWasCheckedBeforeRequestingClarification() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "where are we with the work", repository: repo)
    let source = try await store.source(id)
    let selector = DiscoverySelector(choice: nil)
    let resolver = GitHubContextResolver(client: try GitHubClient(transport: StatusEvidenceAPI()), selector: selector)
    do {
        _ = try await resolver.resolve(source: source, candidates: [], investigationGoal: "Check current work status", discoverPullRequest: true)
        Issue.record("Expected ambiguity after discovery")
    } catch let question as InspectionContextQuestion {
        #expect(question.prompt.contains("I checked o/r"))
        #expect(question.prompt.contains("#3") && question.prompt.contains("#5"))
        #expect(question.prompt.contains("equally plausible"))
        #expect(await selector.calls == 1)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_REQUEST_POLICY"] == "1"))
func liveDiscoverySelectsDeletionPRFromOpenListAndTaskBranchWithoutANumberHint() async throws {
    let (root, repo) = try await policyRepository(); defer { try? FileManager.default.removeItem(atPath: root) }
    let store = try Store(path: root + "/state.sqlite")
    let owner = try await store.createAgentTask(goal: "Add support for deleting todos", repository: repo, kind: .mock)
    try await store.writeOutput(taskID: owner.id, itemID: "branch", kind: "assistant", text: "Deletion implementation is on feature-remove. The command is todo remove <id>, without a delete alias.")
    try await store.archive(owner.id)
    let id = try await store.injectSource(body: "where are we with the delete command work", repository: repo)
    let source = try await store.source(id)
    let resolver = GitHubContextResolver(client: try GitHubClient(transport: StatusEvidenceAPI()))
    let context = try #require(await resolver.resolve(source: source, candidates: store.triageCandidates(repository: repo, includeArchived: true), includeEvidence: true, investigationGoal: "Determine current status of todo deletion work", discoverPullRequest: true))
    #expect(context.pullRequest == 5)
    #expect(context.discoveryReason?.contains("3 open PRs") == true)
    #expect(context.liveEvidence?.contains("Merged: true") == true)
}
