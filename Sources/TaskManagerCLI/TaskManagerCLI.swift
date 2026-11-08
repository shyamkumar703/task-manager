import Foundation
import TaskManagerCore
import TaskManagerPersistence
import CodexTransport
import GitHubIntegration
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
        let known = ["init", "add", "list", "show", "status", "resume", "message", "ask", "answer", "questions", "journal", "ingest", "route", "propose-comment", "proposals", "decide", "github-import", "github-prs", "tui", "serve", "coordinator-stop", "agent-add", "transcript"]
        guard known.contains(command) else { throw ManagerError.invalid("Unknown command: \(command). Run task-manager help.") }
        try FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        statePath = URL(fileURLWithPath: statePath).standardizedFileURL.resolvingSymlinksInPath().path
        let store = try Store(path: URL(fileURLWithPath: statePath).appendingPathComponent("state.sqlite").path)
        func count(_ expected: Int) throws {
            guard args.count == expected else { throw ManagerError.invalid("Incorrect arguments for \(command). Run task-manager help.") }
        }
        switch command {
        case "serve":
            try count(0)
            try await Daemon.serve(stateDirectory: statePath)
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
        case "transcript":
            try count(1)
            try output(await store.outputs(taskID: args[0]))
        case "init":
            try count(0)
            print("State initialized at \(statePath). Launch tui to start the coordinator.")
        case "add":
            guard args.count == 1 || args.count == 2 else { throw ManagerError.invalid("add GOAL [SOURCE_KEY]") }
            try output(await store.createTask(goal: args[0], sourceKey: args.count == 2 ? args[1] : nil))
        case "list": try count(0); try output(await store.tasks())
        case "show":
            try count(1)
            try output(await store.task(args[0]))
            try output(await store.messages(taskID: args[0]))
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
      coordinator-stop                      Pause workers and stop coordinator
      agent-add mock|codex REPO GOAL         Queue a child task (coordinator must be running)
      transcript TASK_ID                    Show saved worker output
      init                                  Initialize durable local state
      codex-probe [EXECUTABLE]               Check app-server handshake; no agent turn
      add GOAL [SOURCE_KEY]                 Create a queued task
      list                                  List tasks as JSON
      show TASK_ID                          Show task and messages
      status TASK_ID STATUS                 Change local task status
      resume TASK_ID                        Resume paused task; preserve pending question
      message TASK_ID TEXT                  Append durable follow-up
      ask TASK_ID QUESTION                  Ask a question (running tasks)
      questions                             List unanswered questions
      answer QUESTION_ID TEXT               Save answer and queue continuation
      ingest EVENTS_JSON                    Ingest normalized source events
      github-import OWNER/REPO PR            Read PR feedback using gh authentication
      github-prs OWNER/REPO AUTHOR           List author's open PRs using gh
      route                                 Route events with known associations
      journal                               Show persistent activity history
      propose-comment TASK_ID PR_URL HEAD TEXT
      proposals                             Inspect exact action proposals
      decide PROPOSAL_ID approve|reject     Record a decision; never publishes

    TUI tasks use mock workers by default; Tab selects real Codex workers.
    q detaches the TUI while workers continue. No external writes are authorized.
    State defaults to ~/Library/Application Support/AutonomousTaskManager.
    Override with --state-dir or TASK_MANAGER_STATE_DIR.
    """
}
