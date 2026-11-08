import CodexTransport
import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private func prGit(_ args: [String]) async throws -> String {
    let result = try await GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git")).run(arguments: args)
    guard result.exitCode == 0 else { throw ManagerError.invalid("git fixture failed: \(args.first ?? "")") }
    return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
private func prRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-context-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}
private func prRepository(_ root: String) async throws -> String {
    let repository = root + "/repo"
    try await prGit(["init", "-b", "main", repository])
    try Data("main has no code symbol\n".utf8).write(to: URL(fileURLWithPath: repository + "/code.txt"))
    try await prGit(["-C", repository, "add", "."])
    try await prGit(["-C", repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "main"])
    try await prGit(["-C", repository, "remote", "add", "origin", "https://github.com/o/r.git"])
    return repository
}
private struct PRMetadata: GitHubHTTPTransport {
    let branch: String
    let sha: String
    func get(_ request: URLRequest) throws -> HTTPResponse {
        #expect(request.url?.path == "/repos/o/r/pulls/4")
        let data = try JSONSerialization.data(withJSONObject: ["number": 4, "title": "Feature", "user": ["login": "o"], "head": ["sha": sha, "ref": branch, "repo": ["full_name": "o/r"]]])
        return HTTPResponse(data: data, status: 200)
    }
}
private actor ResumedPRWorker: AgentConnection {
    nonisolated let events: AsyncStream<CodexClient.Event>
    let output: AsyncStream<CodexClient.Event>.Continuation
    var resumed: JSONValue?
    init() { let stream = AsyncStream<CodexClient.Event>.makeStream(); events = stream.stream; output = stream.continuation }
    func connect() {}
    func stop() { output.finish() }
    func request(_ method: String, params: JSONValue) -> JSONValue {
        if method == "thread/resume" { resumed = params; return .object(["thread": .object(["id": .string("original-thread")])]) }
        if method == "turn/start" {
            output.yield(.init(method: "item/completed", params: .object(["threadId": .string("original-thread"), "item": .object(["id": .string("final"), "type": .string("agentMessage"), "text": .string(#"{"status":"completed","text":"Follow-up verified"}"#)])])))
            output.yield(.init(method: "turn/completed", params: .object(["threadId": .string("original-thread"), "turn": .object(["status": .string("completed")])])))
            return .object(["turn": .object(["id": .string("follow-up")])])
        }
        return .object([:])
    }
}

@Test func prFollowupResolvesCompletedOwnerAndResumesExactWorktreeAndThread() async throws {
    let root = try prRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await prRepository(root)
    let store = try Store(path: root + "/state.sqlite")
    let owner = try await store.createAgentTask(goal: "Implement feature", repository: repository, kind: .codex)
    let workspace = try await Workspaces(stateDirectory: root).prepare(taskID: owner.id, repository: repository)
    try await store.setWorkspace(taskID: owner.id, path: workspace)
    try await store.setThread(taskID: owner.id, threadID: "original-thread")
    try await store.transition(owner.id, to: .running); try await store.transition(owner.id, to: .completed)
    let sha = try await prGit(["-C", workspace, "rev-parse", "HEAD"])
    let branch = "task-manager/" + owner.id
    let client = try GitHubClient(transport: PRMetadata(branch: branch, sha: sha))
    try await store.ingest([SourceEvent(integration: "github", sourceID: "review-1", revision: "1", associationKey: "github:o/r:pr:4", body: "Make the function more readable", url: "https://github.com/o/r/pull/4#discussion_r1")], repository: repository)
    let source = try #require(await store.claimTriageEvent())
    let context = try #require(await GitHubContextResolver(client: client).resolve(source: source, candidates: store.triageCandidates(repository: repository)))
    #expect(context.owningTaskID == owner.id)
    #expect(context.checkout.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path)
    _ = try await store.recordGitHubContext(eventID: source.id, context: context)
    try await store.applyTriage(eventID: source.id, decision: .init(action: .create, goal: "Duplicate PR refactor", reason: "Mistaken new-work classification"))
    #expect(try await store.source(source.id).disposition == .waitingForUser)
    #expect(try await store.tasks().count == 1)
    try await store.answerSource(eventID: source.id, text: "Continue the original task")
    _ = try #require(await store.claimTriageEvent())
    try await store.applyTriage(eventID: source.id, decision: .init(action: .route, taskID: owner.id, reason: "PR refactor continues the original implementation"))
    #expect(try await store.task(owner.id).status == .queued)
    let before = try await prGit(["-C", repository, "worktree", "list", "--porcelain"])
    let worker = ResumedPRWorker()
    let coordinator = Coordinator(store: store, stateDirectory: root, factory: { worker })
    try await coordinator.tick()
    for _ in 0..<300 {
        if await worker.resumed != nil, try await store.task(owner.id).status == .completed { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await worker.resumed?["threadId"]?.string == "original-thread")
    #expect(await worker.resumed?["cwd"]?.string == workspace)
    #expect(try await store.tasks().count == 1)
    #expect(try await prGit(["-C", repository, "worktree", "list", "--porcelain"]) == before)
    #expect(try await store.messages(taskID: owner.id, pendingOnly: true).isEmpty)
    let reopened = try Store(path: root + "/state.sqlite")
    #expect(try await reopened.source(source.id).githubContext?.headBranch == branch)
    await coordinator.shutdown()
}

@Test func prQuestionsReuseCheckedOutBranchWithLocalEditsRatherThanMain() async throws {
    let root = try prRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await prRepository(root)
    try await prGit(["-C", repository, "checkout", "-b", "feature-code"])
    try Data("code is the exit status\n".utf8).write(to: URL(fileURLWithPath: repository + "/code.txt"))
    let sha = try await prGit(["-C", repository, "rev-parse", "HEAD"])
    let store = try Store(path: root + "/state.sqlite")
    try await store.ingest([SourceEvent(integration: "github", sourceID: "question", revision: "1", associationKey: "github:o/r:pr:4", body: "What does code refer to here?", url: "https://github.com/o/r/pull/4#discussion_r1")], repository: repository)
    let source = try #require(await store.claimTriageEvent())
    let context = GitHubRoutingContext(repository: "o/r", pullRequest: 4, headBranch: "feature-code", headSHA: sha, headRepository: "o/r")
    let contextual = try await store.recordGitHubContext(eventID: source.id, context: context)
    let snapshot = try await Workspaces(stateDirectory: root).prepareExploration(taskID: UUID().uuidString, repository: repository, source: contextual)
    #expect(URL(fileURLWithPath: snapshot.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: repository).resolvingSymlinksInPath().path)
    #expect(snapshot.reference == "refs/heads/feature-code")
    #expect(snapshot.provenance?.contains("uncommitted changes") == true)
    #expect(try String(contentsOfFile: snapshot.path + "/code.txt", encoding: .utf8) == "code is the exit status\n")
    #expect(!FileManager.default.fileExists(atPath: root + "/worktrees"))
}

@Test func prHeadWithoutCheckoutUsesCorrectCommitAndMissingCommitAsksInsteadOfMain() async throws {
    let root = try prRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await prRepository(root)
    try await prGit(["-C", repository, "checkout", "-b", "feature-code"])
    try Data("feature code\n".utf8).write(to: URL(fileURLWithPath: repository + "/code.txt"))
    try await prGit(["-C", repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-am", "feature", "--no-gpg-sign"])
    let sha = try await prGit(["-C", repository, "rev-parse", "HEAD"])
    try await prGit(["-C", repository, "checkout", "main"])
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "What is code?", repository: repository)
    _ = try await store.claimTriageEvent()
    let source = try await store.recordGitHubContext(eventID: id, context: .init(repository: "o/r", pullRequest: 4, headBranch: "feature-code", headSHA: sha, headRepository: "o/r"))
    let workspaces = Workspaces(stateDirectory: root)
    let snapshot = try await workspaces.prepareExploration(taskID: UUID().uuidString, repository: repository, source: source)
    #expect(snapshot.sha == sha)
    #expect(try String(contentsOfFile: snapshot.path + "/code.txt", encoding: .utf8) == "feature code\n")
    let missing = try await store.recordGitHubContext(eventID: id, context: .init(repository: "o/r", pullRequest: 4, headBranch: "missing-branch", headSHA: String(repeating: "a", count: 40), headRepository: "o/r"))
    await #expect(throws: InspectionContextQuestion.self) { try await workspaces.prepareExploration(taskID: UUID().uuidString, repository: repository, source: missing) }
    #expect(try await prGit(["-C", repository, "branch", "--show-current"]) == "main")
}

@Test func namedBranchContextAndAmbiguousPRLinksDoNotDefaultToMain() async throws {
    let root = try prRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await prRepository(root)
    try await prGit(["-C", repository, "checkout", "-b", "named-feature"])
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "Explain code on branch `named-feature`", repository: repository)
    let source = try await store.source(id)
    let snapshot = try await Workspaces(stateDirectory: root).prepareExploration(taskID: UUID().uuidString, repository: repository, source: source)
    #expect(snapshot.reference == "refs/heads/named-feature")
    let ambiguous = try await store.injectSource(body: "Compare https://github.com/o/r/pull/4 and https://github.com/o/r/pull/5", repository: repository)
    let ambiguousSource = try await store.source(ambiguous)
    #expect(throws: InspectionContextQuestion.self) { try GitHubContextResolver.pullRequest(in: ambiguousSource) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TASK_MANAGER_LIVE_PR_TRIAGE"] == "1"))
func liveMasterRoutesPRReviewToCompletedImplementationOwner() async throws {
    let root = try prRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await prRepository(root)
    let store = try Store(path: root + "/state.sqlite")
    let task = try await store.createAgentTask(goal: "Build a command to add a due date to a todo", repository: repository, kind: .mock)
    try await store.transition(task.id, to: .running); try await store.transition(task.id, to: .completed)
    try await store.ingest([SourceEvent(integration: "github", sourceID: "review", revision: "1", associationKey: "github:o/r:pr:4", body: "File: Sources/TodoList/main.swift\nLine: 35\n\nCan you make this function's logic more explicit and readable, using descriptive intermediate variables?", url: "https://github.com/o/r/pull/4#discussion_r1")], repository: repository)
    let source = try #require(await store.claimTriageEvent())
    let context = GitHubRoutingContext(repository: "o/r", pullRequest: 4, headBranch: "task-manager/" + task.id, headSHA: String(repeating: "a", count: 40), headRepository: "o/r", owningTaskID: task.id)
    let contextual = try await store.recordGitHubContext(eventID: source.id, context: context)
    let decision = try await CodexMasterTriage(stateDirectory: root).decide(event: contextual, candidates: store.triageCandidates(repository: repository))
    #expect(decision.action == .route)
    #expect(decision.taskID == task.id)
}

@Test func forkPRDoesNotReuseUnrelatedSameNamedBranch() async throws {
    let root = try prRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
    let repository = try await prRepository(root)
    try await prGit(["-C", repository, "branch", "feature"])
    try await prGit(["-C", repository, "checkout", "-b", "fork-changes"])
    try Data("fork version\n".utf8).write(to: URL(fileURLWithPath: repository + "/code.txt"))
    try await prGit(["-C", repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-am", "fork"])
    let forkSHA = try await prGit(["-C", repository, "rev-parse", "HEAD"])
    try await prGit(["-C", repository, "checkout", "feature"])
    let store = try Store(path: root + "/state.sqlite")
    let id = try await store.injectSource(body: "Explain fork PR code", repository: repository)
    _ = try await store.claimTriageEvent()
    let source = try await store.recordGitHubContext(eventID: id, context: .init(repository: "o/r", pullRequest: 4, headBranch: "feature", headSHA: forkSHA, headRepository: "fork/r"))
    let snapshot = try await Workspaces(stateDirectory: root).prepareExploration(taskID: UUID().uuidString, repository: repository, source: source)
    #expect(snapshot.reference == "refs/pull/4/head")
    #expect(snapshot.sha == forkSHA)
    #expect(try String(contentsOfFile: snapshot.path + "/code.txt", encoding: .utf8) == "fork version\n")
    #expect(try String(contentsOfFile: repository + "/code.txt", encoding: .utf8) == "main has no code symbol\n")
}
