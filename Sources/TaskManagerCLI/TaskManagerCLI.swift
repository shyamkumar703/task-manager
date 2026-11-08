import Foundation
import TaskManagerCore
import TaskManagerPersistence
import CodexTransport
import GitHubIntegration
import SlackIntegration
import TaskManagerRuntime
import TaskManagerTUI

@main
struct TaskManagerCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        var args = arguments
        var statePath = ProcessInfo.processInfo.environment["TASK_MANAGER_STATE_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AutonomousTaskManager").path
        if args.first == "--state-dir" {
            guard args.count >= 3 else { throw ManagerError.invalid("--state-dir requires a path and command") }
            statePath = args[1]
            args.removeFirst(2)
        }
        guard let command = args.first, command != "help", command != "--help" else { print(help); return }
        args.removeFirst()
        if command == "codex-probe" {
            guard args.count <= 1 else { throw ManagerError.invalid("codex-probe [EXECUTABLE]") }
            let executable: String
            if let path = args.first {
                executable = URL(fileURLWithPath: path).standardizedFileURL.path
            } else {
                let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                guard let path = paths.map({ String($0) + "/codex" }).first(where: FileManager.default.isExecutableFile(atPath:)) else {
                    throw ManagerError.notFound("codex was not found on PATH")
                }
                executable = path
            }
            let client = CodexClient()
            do {
                try await client.start(executable: URL(fileURLWithPath: executable))
                try output(await client.initialize())
                await client.stop()
            } catch {
                await client.stop()
                throw error
            }
            return
        }
        let known = ["init", "add", "list", "show", "status", "resume", "message", "ask", "answer", "questions", "journal", "ingest", "route", "propose-comment", "proposals", "decide", "github-import", "github-poll", "github-watch", "github-discover", "github-sources", "github-enable", "github-disable", "github-prs", "tui", "serve", "coordinator-start", "coordinator-stop", "agent-add", "transcript", "archive", "restore", "terminal", "release-terminal", "source-inject", "source-events", "source-answer", "source-retry", "source-ignore", "source-unignore", "source-investigate", "actions", "action-done", "action-dismiss", "slack-connect", "slack-conversations", "slack-watch", "slack-sources", "slack-enable", "slack-disable", "slack-poll"]
        guard known.contains(command) else { throw ManagerError.invalid("Unknown command: \(command). Run task-manager help.") }
        try FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        statePath = URL(fileURLWithPath: statePath).standardizedFileURL.resolvingSymlinksInPath().path
        let store = try Store(path: URL(fileURLWithPath: statePath).appendingPathComponent("state.sqlite").path)
        func count(_ expected: Int) throws {
            guard args.count == expected else { throw ManagerError.invalid("Incorrect arguments for \(command). Run task-manager help.") }
        }
        switch command {
        case "actions": try count(0); try output(await store.userActions())
        case "action-done", "action-dismiss":
            try count(1); try await store.resolveUserAction(args[0], dismiss: command == "action-dismiss")
        case "slack-conversations":
            try count(0); try output(await SlackDiscovery.discover(stateDirectory: statePath))
        case "slack-sources": try count(0); try output(await store.slackSources())
        case "slack-watch":
            guard args.count == 3 || args.count == 4 else { throw ManagerError.invalid("slack-watch WORKSPACE_ID CHANNEL_ID LOCAL_REPO [SECONDS]") }
            let interval = args.count == 4 ? Int(args[3]) : 60
            guard let interval else { throw ManagerError.invalid("Interval must be seconds") }
            let discovered = try await SlackDiscovery.discover(stateDirectory: statePath)
            guard let item = discovered.first(where: { $0.connection.workspaceID == args[0] && $0.conversation.id == args[1] }) else { throw ManagerError.notFound("Conversation was not found in connected Slack workspaces") }
            print(try await store.addSlackSource(workspaceID: item.connection.workspaceID, workspaceName: item.connection.workspaceName, userID: item.connection.userID, channelID: item.conversation.id, channelName: item.conversation.name, repository: args[2], intervalSeconds: interval))
        case "slack-enable", "slack-disable":
            try count(1); try await store.setSlackSourceEnabled(args[0], enabled: command == "slack-enable")
        case "slack-poll":
            try count(1)
            guard let source = try await store.slackSources().first(where: { $0.id == args[0] }) else { throw ManagerError.notFound("Unknown Slack source") }
            let cursor = try await store.pollingCursor(sourceKey: source.id, repository: source.repository, workerKind: .codex)
            let client = SlackClient(token: try SlackConnection.token(workspaceID: source.workspaceID, userID: source.userID))
            let events = try await client.feedback(workspace: source.workspaceID, channel: source.channelID)
            let inserted = try await store.commitSlackPoll(source.id, expectedGeneration: cursor?.generation, events: events)
            print(cursor == nil ? "Baselined \(inserted) historical Slack revisions" : "Queued \(inserted) new Slack revisions")
        case "slack-connect":
            try count(0)
            let token = try await SlackConnection.promptToken()
            do {
                let info = try await SlackConnection.connect(token: token, stateDirectory: statePath)
                let message = "Connected to \(info.workspaceName). Your token is saved in macOS Keychain. Connected workspaces are automatically discovered and monitored by the coordinator."
                print(message)
                fflush(stdout)
                await SlackConnection.showResult(title: "Slack connected", message: message)
            } catch {
                await SlackConnection.showResult(title: "Slack connection failed", message: String(describing: error))
                throw error
            }
        case "serve":
            try count(0)
            try await Daemon.serve(stateDirectory: statePath)
        case "coordinator-start":
            try count(0)
            _ = try await Daemon.start(executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, stateDirectory: statePath)
            print("Coordinator started or updated; connected Slack workspaces are monitored automatically.")
        case "coordinator-stop":
            try count(0)
            try Daemon.requestStop(stateDirectory: statePath)
            print("Stop requested. Active tasks will be paused.")
        case "tui":
            guard args.count <= 1 else { throw ManagerError.invalid("tui [REPOSITORY_PATH]") }
            let repository = URL(fileURLWithPath: args.first ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let ui = await TaskManagerTUI(store: store, stateDirectory: statePath, repository: repository, executable: executable)
            try await ui.run()
        case "agent-add":
            try count(3)
            guard let kind = WorkerKind(rawValue: args[0]) else { throw ManagerError.invalid("Worker kind must be mock or codex") }
            try output(await store.createAgentTask(goal: args[2], repository: args[1], kind: kind))
        case "source-inject":
            guard args.count == 3 || args.count == 4, let kind = WorkerKind(rawValue: args[0]) else { throw ManagerError.invalid("source-inject mock|codex REPO TEXT [ASSOCIATION_KEY]") }
            print(try await store.injectSource(body: args[2], repository: args[1], workerKind: kind, associationKey: args.count == 4 ? args[3] : nil))
        case "source-events": try count(0); try output(await store.sources())
        case "source-answer", "source-retry", "source-ignore", "source-unignore", "source-investigate":
            try count(command == "source-answer" ? 2 : 1)
            guard let id = Int64(args[0]) else { throw ManagerError.invalid("Source event ID must be an integer") }
            if command == "source-answer" { try await store.answerSource(eventID: id, text: args[1]) }
            else if command == "source-retry" { try await store.retrySource(id) }
            else if command == "source-investigate" { print(try await store.investigateSource(id) ?? "Project question queued; use source-answer") }
            else if command == "source-unignore" { try await store.unignoreSource(id) }
            else { try await store.ignoreSource(id) }
        case "archive": try count(1); try await store.archive(args[0])
        case "restore": try count(1); try await store.restore(args[0])
        case "release-terminal": try count(1); try await store.releaseTerminal(taskID: args[0])
        case "terminal":
            try count(1)
            guard isatty(STDIN_FILENO) != 0 else { throw ManagerError.invalid("terminal requires an interactive TTY") }
            let handoff = try await ManualTerminal.prepare(store: store, taskID: args[0], stateDirectory: statePath)
            do {
                _ = try await ManualTerminal.runShell(session: handoff)
                try await store.releaseTerminal(taskID: args[0])
            } catch {
                try? await store.releaseTerminal(taskID: args[0])
                throw error
            }
        case "transcript":
            try count(1)
            try output(await store.outputs(taskID: args[0]))
        case "init":
            try count(0)
            print("State initialized at \(statePath). Launch tui to start the coordinator.")
        case "add":
            guard args.count == 1 || args.count == 2 else { throw ManagerError.invalid("add GOAL [SOURCE_KEY]") }
            try output(await store.createTask(goal: args[0], sourceKey: args.count == 2 ? args[1] : nil))
        case "list":
            guard args.isEmpty || args == ["--all"] else { throw ManagerError.invalid("list [--all]") }
            try output(await store.tasks(includeArchived: args == ["--all"]))
        case "show":
            try count(1)
            try output(await store.task(args[0]))
            try output(await store.messages(taskID: args[0]))
            if let session = try await store.agentSession(taskID: args[0]) { try output(session) }
        case "status":
            try count(2)
            guard let status = TaskStatus(rawValue: args[1]) else { throw ManagerError.invalid("Invalid task status") }
            try await store.transition(args[0], to: status)
        case "resume": try count(1); try await store.resume(args[0])
        case "message": try count(2); print(try await store.addMessage(taskID: args[0], body: args[1]))
        case "ask": try count(2); print(try await store.ask(taskID: args[0], prompt: args[1]))
        case "answer": try count(2); try await store.answer(questionID: args[0], text: args[1])
        case "questions": try count(0); try output(await store.questions())
        case "journal": try count(0); try output(await store.journal())
        case "ingest":
            try count(1)
            let events = try JSONDecoder().decode([SourceEvent].self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
            print("Inserted \(try await store.ingest(events)) events")
        case "github-prs":
            try count(2)
            let repository = try GitHubRepository(args[0])
            let client = try GitHubClient()
            try output(await client.openPullRequests(in: repository, author: args[1]))
        case "github-discover":
            try count(1)
            try output(await GitHubDiscovery().discover(checkout: args[0]))
        case "github-watch":
            if args.count == 4 {
                guard let interval = Int(args[3]) else { throw ManagerError.invalid("Interval must be seconds") }
                print(try await store.addGitHubSource(repository: args[0], localRepository: args[1], author: args[2], intervalSeconds: interval))
            } else {
                guard (1...2).contains(args.count) else { throw ManagerError.invalid("Use github-watch LOCAL_REPO [SECONDS]") }
                let interval = args.count == 2 ? Int(args[1]) : 60
                guard let interval else { throw ManagerError.invalid("Interval must be seconds") }
                let client = try GitHubClient()
                let login = try await client.authenticatedLogin()
                guard let remote = try await GitHubDiscovery(client: client).checkoutRepository(args[0]) else { throw ManagerError.invalid("Checkout origin is not a supported GitHub.com remote") }
                print(try await store.addGitHubSource(repository: remote.slug, localRepository: args[0], author: login, intervalSeconds: interval))
            }
        case "github-sources": try count(0); try output(await store.gitHubSources())
        case "github-enable", "github-disable":
            try count(1); try await store.setGitHubSourceEnabled(args[0], enabled: command == "github-enable")
        case "github-poll":
            try count(3)
            guard let pr = Int(args[1]), pr > 0 else { throw ManagerError.invalid("PR number must be positive") }
            let repository = try GitHubRepository(args[0])
            let key = repository.associationKey(pr: pr)
            let first = try await store.pollingCursor(sourceKey: key, repository: args[2], workerKind: .codex) == nil
            let poller = GitHubPoller(store: store, client: try GitHubClient())
            let inserted = try await poller.poll(repository: repository, pr: pr, localRepository: args[2])
            print(first ? "Baselined \(inserted) historical revisions; no new work queued" : "Queued \(inserted) new feedback revisions")
        case "github-import":
            try count(2)
            guard let pr = Int(args[1]), pr > 0 else { throw ManagerError.invalid("PR number must be positive") }
            let repository = try GitHubRepository(args[0])
            let client = try GitHubClient()
            let events = try await client.feedback(in: repository, pr: pr)
            print("Inserted \(try await store.ingest(events)) events; routed \(try await store.routeKnownEvents())")
        case "route": try count(0); print("Routed \(try await store.routeKnownEvents()); pending \(try await store.pendingEventCount())")
        case "propose-comment":
            try count(4)
            print(try await store.proposeComment(taskID: args[0], target: args[1], body: args[3], expectedHead: args[2]))
        case "proposals": try count(0); try output(await store.proposals())
        case "decide":
            try count(2)
            guard ["approve", "reject"].contains(args[1]) else { throw ManagerError.invalid("Decision must be approve or reject") }
            try await store.decide(proposalID: args[0], approve: args[1] == "approve")
            print("Decision recorded. Remote execution is not implemented; nothing was published.")
        default: break
        }
    }

    static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static let help = """
    task-manager [--state-dir PATH] COMMAND

      tui [REPOSITORY_PATH]                 Open TUI; start/attach background coordinator
      serve                                 Run coordinator in foreground
      coordinator-start                     Start or update the persistent coordinator
      coordinator-stop                      Pause workers and stop coordinator
      agent-add mock|codex REPO GOAL         Queue a child task (coordinator must be running)
      transcript TASK_ID                    Show saved worker output
      source-inject mock|codex REPO TEXT [ASSOCIATION_KEY]
                                            Inject a mock source; real master chooses its destination
      source-events                         Show incoming events and master decisions
      actions                               List suggested replies and user actions
      action-done ID                        Mark a manual reply action done; never sends
      action-dismiss ID                     Dismiss a reply action
      slack-connect                         Secure dialog to verify and save a Slack user token
      slack-conversations                   Discover connected Slack channels and DMs
      slack-watch WORKSPACE_ID CHANNEL_ID LOCAL_REPO [SECONDS]
                                            Enable automatic conversation polling
      slack-sources                         List Slack polling health
      slack-enable SOURCE_ID                Enable Slack conversation polling
      slack-disable SOURCE_ID               Disable Slack conversation polling
      slack-poll SOURCE_ID                  Poll a configured Slack conversation once
      source-answer EVENT_ID TEXT           Answer master clarification
      source-retry EVENT_ID                  Retry failed triage
      source-investigate EVENT_ID           Start independent source-context exploration
      source-unignore EVENT_ID              Reconsider an ignored event through master triage
      source-ignore EVENT_ID                Ignore a pending source event
      init                                  Initialize durable local state
      codex-probe [EXECUTABLE]               Check app-server handshake; no agent turn
      add GOAL [SOURCE_KEY]                 Create a queued task
      list [--all]                          List visible tasks, or include archived history
      archive TASK_ID                       Stop work and remove task from list
      restore TASK_ID                       Restore task to list without starting it
      terminal TASK_ID                      Open interactive shell in child worktree
      release-terminal TASK_ID              Clear manual ownership after a crashed terminal
      show TASK_ID                          Show task and messages
      status TASK_ID STATUS                 Change local task status
      resume TASK_ID                        Resume paused task; preserve pending question
      message TASK_ID TEXT                  Append durable follow-up
      ask TASK_ID QUESTION                  Ask a question (running tasks)
      questions                             List unanswered questions
      answer QUESTION_ID TEXT               Save answer and queue continuation
      ingest EVENTS_JSON                    Ingest normalized source events
      github-watch LOCAL_REPO [SECONDS]     Detect gh identity and origin; enable automatic polling
      github-discover LOCAL_REPO            Discover gh identity and available repositories
      github-sources                        List repository polling health
      github-enable ID                      Enable automatic repository polling
      github-disable ID                     Disable automatic repository polling
      github-poll OWNER/REPO PR LOCAL_REPO   Poll once with a durable cursor; first poll baselines
      github-import OWNER/REPO PR            Read PR feedback using gh authentication
      github-prs OWNER/REPO AUTHOR           List author's open PRs using gh
      route                                 Route events with known associations
      journal                               Show persistent activity history
      propose-comment TASK_ID PR_URL HEAD TEXT
      proposals                             Inspect exact action proposals
      decide PROPOSAL_ID approve|reject     Record a decision; never publishes

    TUI: Home surfaces questions/replies in Needs you. 1/2/3 switch views; hjkl and Ctrl-W navigate panes.
    New manual tasks use Codex by default; M selects mock mode. Tab cycles panes.
    q detaches the TUI while workers continue. Workers do not publish changes.
    A task terminal allows you to run git commit/push manually.
    State defaults to ~/Library/Application Support/AutonomousTaskManager.
    Override with --state-dir or TASK_MANAGER_STATE_DIR.
    """
}
