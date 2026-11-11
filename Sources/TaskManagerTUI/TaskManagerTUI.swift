import CLocalSupport
import Darwin
import Foundation
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime

@MainActor
public final class TaskManagerTUI {
    private enum Page { case home, activity, connections, repositories, usage }
    private enum Composer {
        case new, message(String), answer(String), source, clarify(Int64, Int, String)
        case repositoryPath(String, String), interval(String, Bool), workspaceInterval(String), filter
        var title: String {
            switch self {
            case .new: "New task goal"
            case .message: "Message child"
            case .answer: "Answer child question"
            case .source: "Simulate incoming source message"
            case .clarify: "Answer source clarification"
            case .repositoryPath(let slug, _): "Local checkout for " + slug
            case .interval: "Polling interval in seconds (1–86400)"
            case .workspaceInterval: "Slack polling interval for ALL channels, in seconds (1–86400)"
            case .filter: "Filter repositories"
            }
        }
    }
    private enum Connection: Identifiable {
        case workspace(SlackWorkspace), slack(SlackSource), github(GitHubSource)
        var id: String {
            switch self {
            case .workspace(let s): "workspace:" + s.id
            case .slack(let s): "slack:" + s.id
            case .github(let s): "github:" + s.id
            }
        }
        func title(names: SlackNameDirectory) -> String {
            switch self {
            case .workspace(let s): "Slack / " + s.name
            case .slack(let s): "  " + names.channel(s.channelID, workspace: s.workspaceID, fallback: s.channelName)
            case .github(let s): "GitHub / " + s.repository
            }
        }
        var subtitle: String {
            switch self {
            case .workspace(let s): s.lastError ?? "Default polling: every \(s.intervalSeconds)s"
            case .slack(let s): !s.enabled ? "Paused" : s.lastError ?? "Every \(s.intervalSeconds)s"
            case .github(let s): !s.enabled ? "Paused" : s.lastError ?? "Every \(s.intervalSeconds)s"
            }
        }
        var hasError: Bool {
            switch self {
            case .workspace(let s): s.lastError != nil
            case .slack(let s): s.enabled && s.lastError != nil
            case .github(let s): s.enabled && s.lastError != nil
            }
        }
    }
    private struct Line {
        let text: String
        let style: Int32
        init(_ text: String, _ style: Int32 = 0) { self.text = text; self.style = style }
    }
    private struct Detail {
        var title: String
        var subtitle: String
        var commands: String
        var lines: [Line]
    }

    private let store: Store
    private let stateDirectory: String
    private let repository: String
    private let executable: URL
    private var daemon: Process?
    private var page: Page = .home
    private var navigation = DashboardNavigation()
    private var tasks: [ManagedTask] = []
    private var questions: [Question] = []
    private var sources: [IncomingSource] = []
    private var actions: [UserAction] = []
    private var attention: [AttentionItem] = []
    private var connections: [Connection] = []
    private var selectedAttentionID: String?
    private var selectedTaskID: String?
    private var selectedSourceID: Int64?
    private var selectedConnectionID: String?
    private var session: AgentSessionRecord?
    private var outputs: [AgentOutput] = []
    private var messages: [TaskMessage] = []
    private var cleanupPlan: WorktreeCleanup.Plan?
    private var taskInfoMode = false
    private var taskInfo: TaskInfo?
    private var usageReport = UsageReport()
    private var taskUsage = UsageReport()
    private var usageIndex = 0
    private var slackNames = SlackNameDirectory()
    private var replySource: IncomingSource?
    private var kind: WorkerKind = .codex
    private var composer: Composer?
    private var input = Data()
    private var notice = "Starting coordinator…"
    private var running = true
    private var initialized = false
    private var help = false
    private var savedNavigation: DashboardNavigation?
    private var discovery: GitHubDiscoveryResult?
    private var discoveryJob: Task<Void, Never>?
    private var repositoryIndex = 0
    private var repositoryFilter = ""
    private var repositoryIndices: [Int] {
        guard let discovery else { return [] }
        return discovery.repositories.indices.filter { repositoryFilter.isEmpty || discovery.repositories[$0].slug.localizedCaseInsensitiveContains(repositoryFilter) }
    }
    private var selectedAttention: AttentionItem? { attention.first { $0.id == selectedAttentionID } }
    private var selectedTask: ManagedTask? { tasks.first { $0.id == selectedTaskID } }
    private var selectedSource: IncomingSource? { sources.first { $0.id == selectedSourceID } }
    private var selectedConnection: Connection? { connections.first { $0.id == selectedConnectionID } }

    public init(store: Store, stateDirectory: String, repository: String, executable: URL) {
        self.store = store; self.stateDirectory = stateDirectory; self.repository = repository; self.executable = executable
    }
    public func run() async throws {
        guard tm_terminal_open() == 0 else { throw ManagerError.invalid("The TUI requires an interactive terminal") }
        defer { discoveryJob?.cancel(); tm_terminal_close() }
        let previous = signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { self.running = false }; termination.resume()
        defer { termination.cancel(); signal(SIGTERM, previous) }
        draw()
        try await store.registerProject(repository: repository)
        daemon = try await Daemon.start(executable: executable, stateDirectory: stateDirectory)
        notice = "Needs you contains every question, reply, approval, or failure requiring your attention."
        var refreshed = ContinuousClock.now.advanced(by: .seconds(-1))
        while running {
            if refreshed.duration(to: .now) >= .milliseconds(250) {
                do { try await reload() } catch { notice = "Error: \(error)" }
                refreshed = .now
            }
            draw()
            for _ in 0..<64 {
                let key = tm_terminal_key(); if key < 0 { break }
                do { try await handle(key) } catch { notice = "Error: \(error)" }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private func reload() async throws {
        let oldAttention = attention.map(\.id), oldTasks = tasks.map(\.id), oldConnections = connections.map(\.id)
        let oldSources = sources.map { String($0.id) }
        let oldIDs = Set(oldAttention)
        tasks = DashboardModel.work(try await store.tasks())
        questions = try await store.questions()
        actions = try await store.userActions()
        usageReport = try await store.usage()
        slackNames = try await store.slackNames()
        sources = try await store.incomingActivity()
        let urgent = try await store.sourcesNeedingAttention()
        // A selected old clarification must remain inspectable even beyond the recent-activity window.
        if let id = selectedSourceID, !sources.contains(where: { $0.id == id }), try await store.isVisibleInActivity(id), let source = try? await store.source(id) { sources.append(source) }
        let slack = try await store.slackSources(), workspaces = try await store.slackWorkspaces(), github = try await store.gitHubSources()
        connections = workspaces.map(Connection.workspace) + slack.sorted { ($0.workspaceName, $0.channelName) < ($1.workspaceName, $1.channelName) }.map(Connection.slack) + github.map(Connection.github)
        attention = DashboardModel.attention(tasks: tasks, questions: questions, sources: urgent, actions: actions, proposals: try await store.proposals(), slack: slack, workspaces: workspaces, github: github)
        selectedAttentionID = DashboardModel.preservedSelection(selectedAttentionID, old: oldAttention, new: attention.map(\.id))
        selectedTaskID = DashboardModel.preservedSelection(selectedTaskID, old: oldTasks, new: tasks.map(\.id))
        selectedConnectionID = DashboardModel.preservedSelection(selectedConnectionID, old: oldConnections, new: connections.map(\.id))
        selectedSourceID = DashboardModel.preservedSelection(selectedSourceID.map(String.init), old: oldSources, new: sources.map { String($0.id) }).flatMap(Int64.init)
        if !initialized {
            navigation.sidebar(attention.isEmpty ? .work : .attention, task: attention.isEmpty)
            initialized = true
        } else {
            let added = attention.filter { !oldIDs.contains($0.id) }.count
            if added > 0 { notice = "\(added) new item\(added == 1 ? "" : "s") in Needs you. Your current selection is unchanged." }
        }
        try await loadTranscript()
    }
    private func loadTranscript() async throws {
        if page == .home, navigation.detailSource == .attention, case .reply(let action) = selectedAttention {
            replySource = try? await store.source(action.sourceEventID)
        } else { replySource = nil }
        let id: String?
        if page == .home { id = navigation.detailSource == .attention ? selectedAttention?.taskID : selectedTaskID }
        else if page == .activity { id = selectedSource?.taskID }
        else { id = nil }
        if let id {
            taskUsage = try await store.usage(taskID: id)
            session = try await store.agentSession(taskID: id)
            outputs = try await store.outputs(taskID: id)
            messages = try await store.messages(taskID: id)
            if taskInfoMode, page == .home, navigation.detailSource == .work {
                if taskInfo?.task.id != id { navigation.viewport = DetailViewport() }
                taskInfo = try await store.taskInfo(id)
            } else { taskInfo = nil }
        } else { session = nil; outputs = []; messages = []; taskInfo = nil; taskUsage = UsageReport() }
    }
    private func show(_ page: Page) {
        self.page = page; help = false
        if page == .home { navigation.sidebar(attention.isEmpty ? .work : .attention, task: attention.isEmpty) }
        else { navigation.sidebar(.work) }
    }
    private func compose(_ value: Composer, text: String = "") { composer = value; input = Data(text.utf8); notice = "" }

    private func handle(_ key: Int32) async throws {
        if let composer { try await edit(key, composer: composer); return }
        if let plan = cleanupPlan {
            if key == 27 || key == 110 { cleanupPlan = nil; notice = "Cleanup cancelled"; return }
            if key == 121, plan.blockers.isEmpty {
                cleanupPlan = nil; notice = "Cleaning up worktree…"; draw()
                try await WorktreeCleanup.execute(plan, store: store, stateDirectory: stateDirectory)
                notice = "Cleanup complete. Task archived; branch and history retained."; try await reload()
            }
            if key == 113 || key == 3 { running = false }
            _ = navigation.handle(key, dashboard: false); navigation.focus = .detail
            return
        }
        if help {
            if key == 63 || key == 27 { help = false; navigation = savedNavigation ?? navigation; savedNavigation = nil; return }
            if let intent = navigation.handle(key, dashboard: page == .home) {
                if intent == .first { navigation.viewport.top() } else if intent == .last { navigation.viewport.bottom() }
                else if case .move(let amount) = intent { navigation.viewport.move(amount) }
                navigation.focus = .detail
                return
            }
            if key == 113 || key == 3 { running = false }
            return
        }
        var navigationKey = key
        if key == tm_key_up() { navigationKey = 107 }
        if key == tm_key_down() { navigationKey = 106 }
        if key == tm_key_left() { navigationKey = 104 }
        if key == tm_key_right() { navigationKey = 108 }
        if key == tm_key_page_up() { navigationKey = 2 }
        if key == tm_key_page_down() { navigationKey = 6 }
        let previousDetailSource = navigation.detailSource
        if let intent = navigation.handle(navigationKey, dashboard: page == .home) {
            switch intent {
            case .move(let amount): moveSelection(amount)
            case .first: moveSelection(Int.min / 2)
            case .last: moveSelection(Int.max / 2)
            case .consumed: break
            }
            if intent != .consumed || previousDetailSource != navigation.detailSource { try await loadTranscript() }; return
        }
        switch key {
        case 113, 3: running = false; return
        case 49, 118: show(.home); try await loadTranscript(); return // v remains a compatibility alias, never required.
        case 50: show(.activity); try await loadTranscript(); return
        case 51: show(.connections); return
        case 52: show(.usage); navigation.focus = .detail; return
        case 67 where page == .activity:
            let count = try await store.clearIncomingActivity()
            selectedSourceID = nil; navigation.viewport = DetailViewport()
            try await reload()
            notice = "Cleared \(count) history entries. Pending reviews/questions/failures remain. U restores history."
            return
        case 85 where page == .activity:
            let count = try await store.restoreIncomingActivity()
            try await reload(); notice = "Restored \(count) activity history entries"
            return
        case 63: savedNavigation = navigation; help = true; navigation.focus = .detail; navigation.viewport = DetailViewport(); return
        case 105 where page == .home:
            if navigation.detailSource == .attention {
                guard let id = selectedAttention?.taskID else { notice = "Select a child task in Work to inspect its history."; return }
                try await openTask(id); taskInfoMode = true
            } else {
                guard selectedTask != nil else { return }
                taskInfoMode.toggle()
            }
            navigation.focus = .detail
            navigation.viewport = DetailViewport(followTail: !taskInfoMode)
            try await loadTranscript(); return
        case 27:
            if page == .home, taskInfoMode {
                taskInfoMode = false; taskInfo = nil; navigation.viewport = DetailViewport(followTail: true)
                return
            }
            if page == .repositories { discoveryJob?.cancel(); show(.connections) }
            else { show(.home) }; try await loadTranscript(); return
        case 77: kind = kind == .codex ? .mock : .codex; notice = "New manual tasks and simulated sources use \(kind.rawValue.uppercased()). Existing tasks keep their runtime."; return
        case 110:
            if page == .connections { discoverRepositories() }
            else if page != .repositories { compose(.new) }
            return
        case 115: if page == .home || page == .activity { compose(.source) }; return
        default: break
        }
        switch page {
        case .home:
            if navigation.detailSource == .attention { try await actOnAttention(key) }
            else { try await actOnTask(key) }
        case .activity: try await actOnSource(key)
        case .connections: try await actOnConnection(key)
        case .repositories: try await actOnRepository(key)
        case .usage: break
        }
    }
    private func edit(_ key: Int32, composer: Composer) async throws {
        switch key {
        case 27: self.composer = nil; input = Data(); notice = "Input cancelled"
        case 10, 13, 343:
            let text = String(decoding: input, as: UTF8.self)
            try requireText(text, name: "Input")
            switch composer {
            case .new:
                selectedTaskID = try await store.createAgentTask(goal: text, repository: repository, kind: kind).id
                page = .home; navigation.sidebar(.work, task: true); notice = "\(kind.rawValue.capitalized) child queued"
            case .message(let id): _ = try await store.addMessage(taskID: id, body: text); notice = "Message saved for child"
            case .answer(let id): try await store.answer(questionID: id, text: text); notice = "Answer saved; child can continue"
            case .clarify(let id, let attempt, let question):
                try await store.answerSource(eventID: id, text: text, expectedAttempt: attempt, expectedQuestion: question)
                notice = "Clarification saved; master will reconsider the message"
            case .source:
                selectedSourceID = try await store.injectSource(body: text, repository: repository, workerKind: kind)
                show(.activity); notice = "Simulated source saved for master review"
            case .repositoryPath(let slug, let login):
                let remote = try await GitHubDiscovery().checkoutRepository(text)
                guard remote?.slug.lowercased() == slug.lowercased() else { throw ManagerError.invalid("Checkout origin does not match " + slug) }
                _ = try await store.addGitHubSource(repository: slug, localRepository: text, author: login)
                show(.connections); notice = "GitHub repository enabled; automatic polling starts at 60s"
            case .interval(let id, let slack):
                guard let seconds = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ManagerError.invalid("Interval must be seconds") }
                if slack { try await store.setSlackSourceInterval(id, seconds: seconds) } else { try await store.setGitHubSourceInterval(id, seconds: seconds) }
                notice = "Polling interval updated to \(seconds)s"
            case .workspaceInterval(let id):
                guard let seconds = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ManagerError.invalid("Interval must be seconds") }
                try await store.setSlackWorkspaceInterval(id, seconds: seconds)
                notice = "Slack workspace polling updated to \(seconds)s for current and future channels"
            case .filter: repositoryFilter = text; repositoryIndex = 0
            }
            self.composer = nil; input = Data()
            try await reload()
        case 14: input.append(10) // Ctrl-N newline; Enter submits.
        case 21: input = Data() // Ctrl-U clear input, never scroll during composition.
        case 23:
            var text = String(decoding: input, as: UTF8.self)
            while text.last?.isWhitespace == true { text.removeLast() }
            while let last = text.last, !last.isWhitespace { text.removeLast() }
            input = Data(text.utf8)
        default:
            if key == 8 || key == 127 || key == tm_key_backspace() {
                var text = String(decoding: input, as: UTF8.self); if !text.isEmpty { text.removeLast() }; input = Data(text.utf8)
            } else if (32...255).contains(key), input.count < 32768 { input.append(UInt8(key)) }
        }
    }
    private func actOnAttention(_ key: Int32) async throws {
        guard let item = selectedAttention else { return }
        let enter = [Int32(10), 13, 343].contains(key)
        if enter {
            switch item { case .sourceQuestion, .workerQuestion: break; default: navigation.focus = .detail }
        }
        if key == 111, let id = item.taskID { try await openTask(id); return }
        switch item {
        case .sourceQuestion(let source):
            if enter || key == 97 { compose(.clarify(source.id, source.attempts, source.question ?? "")) }
            if key == 120 { try await store.ignoreSource(source.id); notice = "Source ignored"; try await reload() }
        case .workerQuestion(let question, _): if enter || key == 97 { compose(.answer(question.id)) }
        case .reply(let action):
            if enter { navigation.focus = .detail }
            if key == 99 { try await ReplyClipboard.copy(action.body); notice = "Reply copied. Review and send it manually in the source thread." }
            if key == 101 { try await store.revealIncomingActivity(action.sourceEventID); selectedSourceID = action.sourceEventID; show(.activity); try await reload() }
            if key == 100 || key == 120 { try await store.resolveUserAction(action.id, dismiss: key == 120); notice = key == 100 ? "Marked replied; nothing was sent by the manager" : "Reply dismissed"; try await reload() }
        case .approval(let proposal):
            if enter { navigation.focus = .detail }
            if key == 97 || key == 120 { try await store.decide(proposalID: proposal.id, approve: key == 97); notice = "Decision recorded. This proposal is not published automatically."; try await reload() }
            if key == 99 { try await ReplyClipboard.copy(proposal.body); notice = "Proposal text copied" }
        case .failedTask(let task): if key == 114 { try await store.transition(task.id, to: .queued); notice = "Child queued to retry"; try await reload() } else if enter { try await openTask(task.id) }
        case .failedSource(let source):
            if key == 114 { try await store.retrySource(source.id); notice = "Source review queued to retry"; try await reload() }
            if key == 120 { try await store.ignoreSource(source.id); try await reload() }
            if enter { selectedSourceID = source.id; show(.activity); try await reload() }
        case .slackProblem(let source): if key == 114 { try await store.setSlackSourceEnabled(source.id, enabled: true); notice = "Slack poll scheduled now"; try await reload() }
        case .slackDiscoveryProblem(let workspace): if key == 114 { try await store.retrySlackDiscovery(workspace.id); notice = "Slack discovery scheduled now"; try await reload() }
        case .githubProblem(let source): if key == 114 { try await store.setGitHubSourceEnabled(source.id, enabled: true); notice = "GitHub poll scheduled now"; try await reload() }
        }
    }
    private func actOnTask(_ key: Int32) async throws {
        guard let task = selectedTask else { return }
        switch key {
        case 10, 13, 343: navigation.focus = .detail
        case 109: compose(.message(task.id))
        case 97: if ![TaskStatus.cancelled, .completed, .failed].contains(task.status), let q = questions.first(where: { $0.taskID == task.id }) { compose(.answer(q.id)) }
        case 112:
            guard task.status == .paused || task.status.canTransition(to: .paused) else { notice = "No active work to pause. d removes this task from the list."; return }
            if task.status == .paused { try await store.resume(task.id) } else { try await store.transition(task.id, to: .paused) }
            try await reload()
        case 114:
            guard [TaskStatus.paused, .completed, .failed].contains(task.status) else { notice = "This child is already active or needs its question answered."; return }
            if task.status == .paused { try await store.resume(task.id) } else { try await store.transition(task.id, to: .queued) }
            notice = "Child queued to continue its saved thread"; try await reload()
        case 100: try await store.archive(task.id); notice = "Task removed from work list; history retained"; try await reload()
        case 120:
            guard task.status.canTransition(to: .cancelled) else { notice = "This task is already finished; d removes it from the list."; return }
            try await store.transition(task.id, to: .cancelled); notice = "Task cancelled"; try await reload()
        case 67:
            notice = "Checking worktree, commits, and shared ownership…"; draw()
            cleanupPlan = try await WorktreeCleanup.preview(store: store, taskID: task.id, stateDirectory: stateDirectory)
            navigation.focus = .detail; navigation.viewport = DetailViewport()
        case 111: try await openWorkspace(task.id)
        case 116: try await openTerminal(task.id)
        default: break
        }
    }
    private func actOnSource(_ key: Int32) async throws {
        guard let source = selectedSource else { return }
        switch key {
        case 10, 13, 343:
            if source.disposition == .waitingForUser { compose(.clarify(source.id, source.attempts, source.question ?? "")) }
            else if let id = source.taskID { try await openTask(id) } else { navigation.focus = .detail }
        case 97: if source.disposition == .waitingForUser { compose(.clarify(source.id, source.attempts, source.question ?? "")) }
        case 114: try await store.retrySource(source.id); notice = "Source queued for retry"; try await reload()
        case 105: _ = try await store.investigateSource(source.id); notice = "Independent exploration queued; its reply will appear in Needs you"; try await reload()
        case 117: try await store.unignoreSource(source.id); notice = "Source unignored; queued for review"; try await reload()
        case 120: try await store.ignoreSource(source.id); notice = "Source ignored"; try await reload()
        case 100:
            try await store.hideIncomingActivity(source.id)
            selectedSourceID = nil; navigation.viewport = DetailViewport()
            try await reload(); notice = "Message hidden from activity. U restores history."
        default: break
        }
    }
    private func actOnConnection(_ key: Int32) async throws {
        guard let connection = selectedConnection else { return }
        if [Int32(10), 13, 343].contains(key) { navigation.focus = .detail; return }
        switch connection {
        case .workspace(let s):
            if key == 114 { try await store.retrySlackDiscovery(s.id); notice = "Discovery scheduled now" }
            if key == 105 { compose(.workspaceInterval(s.id), text: String(s.intervalSeconds)) }
        case .slack(let s):
            if key == 112 || key == 114 { try await store.setSlackSourceEnabled(s.id, enabled: key == 114 || !s.enabled); notice = key == 114 ? "Poll scheduled now" : "Conversation polling updated" }
            if key == 105 { compose(.interval(s.id, true), text: String(s.intervalSeconds)) }
        case .github(let s):
            if key == 112 || key == 114 { try await store.setGitHubSourceEnabled(s.id, enabled: key == 114 || !s.enabled); notice = key == 114 ? "Poll scheduled now" : "Repository polling updated" }
            if key == 105 { compose(.interval(s.id, false), text: String(s.intervalSeconds)) }
        }
        try await reload()
    }
    private func actOnRepository(_ key: Int32) async throws {
        if key == 47 { compose(.filter); return }
        if key == 99 { repositoryFilter = ""; repositoryIndex = 0; return }
        if key == 114 { discoverRepositories(); return }
        guard [Int32(10), 13, 343].contains(key), let discovery, repositoryIndices.indices.contains(repositoryIndex) else { return }
        let candidate = discovery.repositories[repositoryIndices[repositoryIndex]]
        if connections.contains(where: { if case .github(let s) = $0 { return s.repository.caseInsensitiveCompare(candidate.slug) == .orderedSame }; return false }) {
            show(.connections); notice = "Repository already configured"; return
        }
        if discovery.current?.slug.lowercased() == candidate.slug.lowercased() {
            _ = try await store.addGitHubSource(repository: candidate.slug, localRepository: repository, author: discovery.login)
            show(.connections); notice = "Current checkout enabled with your gh identity; automatic polling every 60s"; try await reload()
        } else { compose(.repositoryPath(candidate.slug, discovery.login)) }
    }
    private func discoverRepositories() {
        guard discoveryJob == nil else { return }
        show(.repositories); discovery = nil; repositoryIndex = 0; repositoryFilter = ""
        notice = "Discovering repositories using your existing gh login…"
        discoveryJob = Task {
            defer { discoveryJob = nil }
            do {
                let result = try await GitHubDiscovery().discover(checkout: repository); try Task.checkCancellation()
                discovery = result; notice = "Select a repository. The current checkout needs no additional input."
            } catch { if !Task.isCancelled { notice = "Discovery failed: \(error). r retries; Esc returns." } }
        }
    }
    private func openTask(_ id: String) async throws {
        guard tasks.contains(where: { $0.id == id }) else { notice = "Task is archived or unavailable; its reply and source remain reviewable here"; return }
        selectedTaskID = id; page = .home; navigation.sidebar(.work, task: true); navigation.focus = .detail
        try await loadTranscript()
    }
    private func openWorkspace(_ id: String) async throws {
        notice = "Opening editor, shared Codex, and shell in tmux…"; draw()
        let workspace = try await TaskWorkspace.load(store: store, taskID: id, stateDirectory: stateDirectory)
        let session = try await workspace.prepareTmux()
        tm_terminal_close()
        do {
            try await TaskWorkspace.focus(session: session)
            notice = "Workspace \(session). Manager continues observing and forwarding source messages."
        } catch { notice = "Workspace error: \(error)" }
        tm_terminal_reclaim_foreground()
        guard tm_terminal_open() == 0 else { running = false; throw ManagerError.invalid("Could not restore terminal UI") }
        try await reload()
    }
    private func openTerminal(_ id: String) async throws {
        notice = "Pausing child and opening its worktree terminal…"; draw()
        let handoff = try await ManualTerminal.prepare(store: store, taskID: id, stateDirectory: stateDirectory)
        tm_terminal_close()
        do {
            _ = try await ManualTerminal.runShell(session: handoff); try await store.releaseTerminal(taskID: id)
            notice = "Returned from terminal. p resumes a paused child."
        } catch { try? await store.releaseTerminal(taskID: id); notice = "Terminal error: \(error)" }
        tm_terminal_reclaim_foreground()
        guard tm_terminal_open() == 0 else { running = false; throw ManagerError.invalid("Could not restore terminal UI") }
        try await reload()
    }
    private func moveSelection(_ delta: Int) {
        func index(_ current: Int, _ count: Int) -> Int { min(max(0, count - 1), max(0, current + delta)) }
        switch page {
        case .home:
            if navigation.focus == .attention {
                if !attention.isEmpty { selectedAttentionID = attention[index(attention.firstIndex { $0.id == selectedAttentionID } ?? 0, attention.count)].id }
            } else if !tasks.isEmpty { selectedTaskID = tasks[index(tasks.firstIndex { $0.id == selectedTaskID } ?? 0, tasks.count)].id }
            navigation.selected(task: navigation.focus == .work)
        case .activity:
            if !sources.isEmpty { selectedSourceID = sources[index(sources.firstIndex { $0.id == selectedSourceID } ?? 0, sources.count)].id }
            navigation.selected()
        case .connections:
            if !connections.isEmpty { selectedConnectionID = connections[index(connections.firstIndex { $0.id == selectedConnectionID } ?? 0, connections.count)].id }
            navigation.selected()
        case .repositories: repositoryIndex = index(repositoryIndex, repositoryIndices.count); navigation.selected()
        case .usage: usageIndex = index(usageIndex, UsagePresentation.roles.count); navigation.selected()
        }
    }

    // MARK: - Rendering
    private func taskStatus(_ status: TaskStatus) -> String {
        status == .waitingForUser ? "Waiting for your answer" : status == .completed ? "Ready for follow-up" : status.rawValue.capitalized
    }
    private func sourceStatus(_ status: SourceDisposition) -> String {
        switch status {
        case .waitingForUser: "Needs clarification"
        case .pending: "Queued for review"
        case .triaging: "Reviewing"
        case .created: "Child created"
        case .routed: "Routed"
        case .ignored: "Ignored"
        case .failed: "Review failed"
        }
    }
    private func single(_ text: String) -> String { TerminalText.clean(text).replacingOccurrences(of: "\n", with: " ") }
    private func section(_ title: String, _ body: String, width: Int, style: Int32 = 0) -> [Line] {
        [Line(title, 1)] + TerminalText.wrap(body, width: width).map { Line($0, style) } + [Line("")]
    }
    private func time(_ value: Double?) -> String { value.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .standard) } ?? "not yet" }
    private func detail(width: Int) -> Detail {
        if let plan = cleanupPlan {
            let blocked = !plan.blockers.isEmpty
            return Detail(title: blocked ? "Cleanup needs attention" : "Clean up this task?", subtitle: plan.taskID, commands: blocked ? "Esc / n: return" : "y: confirm cleanup   Esc / n: cancel", lines: section("CLEANUP PREVIEW", plan.summary, width: width) + (blocked ? section("BLOCKED", plan.blockers.joined(separator: "\n\n"), width: width, style: 4) : section("CONFIRM", "Press y to perform this cleanup and archive the task.", width: width, style: 4)))
        }
        if help { return helpDetail(width: width) }
        switch page {
        case .usage:
            let (role, title) = UsagePresentation.roles[usageIndex]
            let report = usageReport.forRole(role)
            let lines = UsagePresentation.sections(report).flatMap { section($0.title, $0.text, width: width, style: $0.style) }
            return Detail(title: title + " · usage & cost", subtitle: "All recorded activity in this state directory", commands: "h: categories   l: details   j/k · Ctrl-U/D: scroll   1: home", lines: lines)
        case .home:
            if navigation.detailSource == .attention {
                if let item = selectedAttention { return attentionDetail(item, width: width) }
                return Detail(title: "All caught up", subtitle: "Questions and replies will appear here as work progresses", commands: "Ctrl-W j: work list   l: detail   n: new task", lines: section("NOTHING WAITING ON YOU", "The coordinator continues monitoring connected sources. New clarification questions, reply drafts, approvals, and actionable failures appear in Needs you automatically.", width: width))
            }
            if let task = selectedTask { return taskDetail(task, width: width) }
            return Detail(title: "Your work starts here", subtitle: "Connected sources can create tasks automatically", commands: "n: new task   3: connection health   ?: help", lines: section("NO TASKS YET", "Create a task with n, or let an incoming source identify work. Questions and reply drafts are surfaced in Needs you without switching views.", width: width))
        case .activity:
            if let source = selectedSource { return sourceDetail(source, width: width) }
            return Detail(title: "Incoming activity", subtitle: "New source messages appear here automatically", commands: "C: clear history   U: restore history   s: simulate incoming message   1: home", lines: section("NO VISIBLE HISTORY", "You're caught up. U restores cleared history. Clearing hides processed messages; task history and Needs you are retained. Pending reviews, questions, and failures stay visible.", width: width))
        case .connections:
            if let c = selectedConnection { return connectionDetail(c, width: width) }
            return Detail(title: "Connections", subtitle: "Source monitoring is owned by the background coordinator", commands: "n: add GitHub repository   1: home", lines: section("GITHUB", "n discovers repositories using your existing gh login and the current checkout's origin.", width: width) + section("SLACK", "Connected Slack workspaces are monitored automatically. To connect one, run task-manager --state-dir PATH slack-connect in a terminal. The token is stored in macOS Keychain.", width: width))
        case .repositories:
            guard let discovery, repositoryIndices.indices.contains(repositoryIndex) else {
                return Detail(title: "Add GitHub repository", subtitle: "Uses your existing gh identity", commands: "r: refresh   Esc: connections", lines: section("DISCOVERY", discoveryJob == nil ? "No matching repositories. Clear the filter with c or refresh with r." : "Discovering your authenticated account and accessible repositories…", width: width))
            }
            let candidate = discovery.repositories[repositoryIndices[repositoryIndex]]
            let current = discovery.current?.slug.lowercased() == candidate.slug.lowercased()
            return Detail(title: candidate.slug, subtitle: "Authenticated as \(discovery.login)", commands: "Enter: add   /: filter   c: clear filter   Esc: back", lines: section("AUTOMATIC POLLING", "Observe your open PRs and their comments/reviews. The first scan records existing history without creating work. Later feedback enters master triage.", width: width) + section("LOCAL CHECKOUT", current ? repository + "\nInferred from origin; no additional input needed." : "After selecting this repository, enter its local checkout path. Polling defaults to 60 seconds.", width: width))
        }
    }
    private func destination(_ url: String) -> String {
        guard let components = URLComponents(string: url), components.scheme == "slack" else { return url }
        let team = components.queryItems?.first { $0.name == "team" }?.value
        let channel = components.queryItems?.first { $0.name == "id" }?.value
        for connection in connections {
            if case .slack(let s) = connection, s.workspaceID == team, s.channelID == channel { return "Slack / \(s.workspaceName) / " + slackNames.channel(s.channelID, workspace: s.workspaceID, fallback: s.channelName) }
        }
        return url
    }
    private func attentionDetail(_ item: AttentionItem, width: Int) -> Detail {
        switch item {
        case .sourceQuestion(let s):
            var d = sourceDetail(s, width: width)
            d.title = "Clarification needed before work can continue"
            d.commands = "Enter / a: answer   x: ignore source   o: child (if linked)"
            return d
        case .workerQuestion(let q, let task):
            return Detail(title: "Your child needs an answer", subtitle: single(task.goal), commands: "Enter / a: answer   o: open child", lines: section("QUESTION", q.prompt, width: width, style: 4) + section("TASK", task.goal, width: width) + section("WHAT HAPPENS NEXT", "Your answer is saved durably and delivered to this child. Other children continue independently.", width: width, style: 3))
        case .reply(let a):
            let original = replySource.map { section("ORIGINAL REQUEST", slackNames.body(of: $0), width: width, style: 3) } ?? []
            return Detail(title: "Reply ready for review", subtitle: destination(a.target), commands: "c: copy reply   d: mark replied   x: dismiss   e: source   o: child", lines: section("SUGGESTED REPLY", a.body, width: width) + original + section("WHERE TO RESPOND", destination(a.target) + "\n" + a.target, width: width, style: 3) + section("NEXT STEP", "Copy the reply with c, review/edit it in the source thread, and send it manually. Then use d to mark this item replied. Dismissing or marking replied does not send a message.", width: width, style: 4) + section("EVIDENCE / INSPECTED SNAPSHOT", a.context, width: width))
        case .approval(let p):
            return Detail(title: "Review proposed action", subtitle: p.kind, commands: "a: approve decision   x: reject   c: copy text   o: child", lines: section("EXACT PROPOSED TEXT", p.body, width: width) + section("TARGET", p.target, width: width) + section("EXPECTED HEAD", p.expectedHead, width: width, style: 3) + section("APPROVAL BEHAVIOR", "Approval records your decision only. Automatic publication for this proposal is not implemented; nothing will be posted by these controls.", width: width, style: 4))
        case .failedTask(let t):
            var d = taskDetail(t, width: width); d.title = "Child needs attention"; d.commands = "r: retry saved child   Enter / o: inspect child"
            let errors = outputs.filter { $0.kind == "error" || $0.kind == "system" }.suffix(3).map(\.text).joined(separator: "\n")
            d.lines = section("WHY IT STOPPED", errors.isEmpty ? "The child failed. Inspect its transcript before retrying." : errors, width: width, style: 6) + d.lines
            return d
        case .failedSource(let s):
            var d = sourceDetail(s, width: width); d.title = "Incoming message could not be reviewed"; d.commands = "r: retry review   x: ignore source   Enter: activity"
            return d
        case .slackProblem(let s): return connectionDetail(.slack(s), width: width)
        case .slackDiscoveryProblem(let s): return connectionDetail(.workspace(s), width: width)
        case .githubProblem(let s): return connectionDetail(.github(s), width: width)
        }
    }
    private func taskDetail(_ task: ManagedTask, width: Int) -> Detail {
        let role = session?.purpose.rawValue ?? "implementation"
        if taskInfoMode, navigation.detailSource == .work, let info = taskInfo, info.task.id == task.id {
            let lines = (UsagePresentation.sections(taskUsage) + TaskInfoPresentation.sections(info, slackNames: slackNames)).flatMap { section($0.title, $0.text, width: width, style: $0.style) }
            return Detail(title: "Task info · " + single(task.goal), subtitle: "\(taskStatus(task.status)) · \(info.sources.count) connection messages · \(info.journal.count) recorded events", commands: "i / Esc: progress   C: cleanup   o: tmux workspace   m: message   j/k · Ctrl-U/D · gg/G: scroll", lines: lines)
        }
        var lines: [Line] = []
        if ![TaskStatus.cancelled, .completed, .failed].contains(task.status), let q = questions.first(where: { $0.taskID == task.id && $0.answer == nil }) { lines += section("ANSWER NEEDED · a responds", q.prompt, width: width, style: 4) }
        if let action = actions.first(where: { $0.taskID == task.id && $0.status == "open" }) { lines += section("REPLY READY · Home → Needs you", action.body, width: width, style: 4) }
        lines += section("GOAL", task.goal, width: width)
        lines += section("USAGE & COST", UsagePresentation.compact(taskUsage) + "\nAPI-equivalent estimate, not a bill. 4 opens the full usage breakdown.", width: width, style: 3)
        if let path = session?.workspace { lines += section("WORKSPACE", path, width: width, style: 3) }
        for output in outputs {
            let text = output.kind == "assistant" ? TerminalText.assistantText(output.text) : output.kind == "user" ? slackNames.envelope(output.text) : output.text
            var label = output.kind.uppercased()
            if output.kind == "user", let message = messages.first(where: { output.itemID == "message-\($0.id)" }) { label += message.delivered ? " · ACCEPTED" : " · QUEUED" }
            let style: Int32 = output.kind == "error" ? 6 : output.kind == "tool" || output.kind == "system" ? 3 : 0
            lines += section(label, text, width: width, style: style)
        }
        if outputs.isEmpty { lines += section("STATUS", "Waiting for the coordinator…", width: width, style: 3) }
        var commands: [String] = ["i: task info"]
        if session?.workspace != nil { commands.append("C: cleanup") }
        if task.status != .cancelled { commands.append("m: message") }
        if ![TaskStatus.cancelled, .completed, .failed].contains(task.status), questions.contains(where: { $0.taskID == task.id && $0.answer == nil }) { commands.append("a: answer") }
        if task.status == .paused || task.status.canTransition(to: .paused) { commands.append(task.status == .paused ? "p: resume" : "p: pause") }
        if session?.workspace != nil { commands.append("o: tmux workspace"); commands.append("t: terminal") }
        if [TaskStatus.paused, .completed, .failed].contains(task.status) { commands.append(task.status == .completed ? "r: continue" : "r: retry") }
        commands.append("d: remove")
        if task.status.canTransition(to: .cancelled) { commands.append("x: cancel") }
        return Detail(title: single(task.goal), subtitle: "\(taskStatus(task.status)) · \(role.capitalized) · \(session?.kind.rawValue.capitalized ?? "Unbound") · \(messages.filter { !$0.delivered }.count) messages pending", commands: commands.joined(separator: "   "), lines: lines)
    }
    private func sourceDetail(_ source: IncomingSource, width: Int) -> Detail {
        var lines: [Line] = []
        if let q = source.question { lines += section("QUESTION · Enter answers", q, width: width, style: 4) }
        if let error = source.lastError { lines += section("REVIEW ERROR", error, width: width, style: 6) }
        lines += section("INCOMING MESSAGE", slackNames.body(of: source), width: width)
        if let reason = source.reason { lines += section("DECISION", reason, width: width) }
        if let c = source.githubContext {
            lines += section("PR CONTEXT", "\(c.repository) #\(c.pullRequest)\nBranch: \(c.headBranch)\nPublished head: \(c.headSHA)\nCheckout: \(c.checkout ?? "No matching local checkout")\nOwning task: \(c.owningTaskID ?? "Not yet associated")", width: width, style: 3)
        }
        if let c = source.slackContext {
            let channel = slackNames.channel(c.channelID, workspace: slackNames.workspace(of: source) ?? "", fallback: c.channelName)
            let context = "\(c.workspaceName) / \(channel)\nTopic: \(c.topic ?? "—")\nPurpose: \(c.purpose ?? "—")\n\(c.precedingMessages.count) preceding messages · \(c.threadMessages.count) thread messages · \(c.projectHistory.count) prior project decisions"
            lines += section("CONTEXT USED", context, width: width, style: 3)
        }
        if let clarification = source.clarification { lines += section("YOUR CLARIFICATION", clarification, width: width) }
        lines += section("SOURCE", source.url, width: width, style: 3)
        if let id = source.taskID {
            let name = tasks.first { $0.id == id }?.goal ?? id
            lines += section("LINKED CHILD", name + (source.messageDelivered.map { $0 ? "\nMessage accepted" : "\nMessage queued" } ?? ""), width: width)
        }
        let commands: String
        switch source.disposition {
        case .waitingForUser: commands = "Enter / a: answer   x: ignore   i: independent investigation"
        case .failed: commands = "r: retry review   x: ignore"
        case .ignored: commands = "u: reconsider ignored message   i: independent investigation"
        case .routed, .created: commands = "Enter: child   i: independent investigation"
        default: commands = "x: ignore   l: inspect message"
        }
        let history = ([SourceDisposition.routed, .created, .ignored].contains(source.disposition) ? "d: hide   " : "") + "C: clear history   U: restore history"
        return Detail(title: "\(source.integration.capitalized) message #\(source.id)", subtitle: "\(sourceStatus(source.disposition)) · \(sourceSummary(source))", commands: commands + "   " + history, lines: lines)
    }
    private func sourceSummary(_ source: IncomingSource) -> String {
        if source.integration == "slack" {
            return "Slack " + [slackNames.channel(of: source), slackNames.author(of: source)].compactMap { $0 }.joined(separator: " · ")
        }
        return destination(source.url) == source.url ? source.integration.capitalized : destination(source.url)
    }
    private func connectionDetail(_ c: Connection, width: Int) -> Detail {
        var lines: [Line] = []
        let commands: String
        switch c {
        case .workspace(let s):
            commands = "i: polling interval (all channels)   r: retry discovery   n: add GitHub repository"
            if let error = s.lastError { lines += section("DISCOVERY ERROR", error, width: width, style: 6) }
            lines += section("MONITORING", "Accessible Slack channels and DMs are discovered and monitored automatically. Press i to update all channels and the default for future channels. Select a channel below to override its interval individually.", width: width)
            lines += section("SCHEDULE", "Default message polling: every \(s.intervalSeconds)s\nConversation discovery: every 60s\nLast discovery: \(time(s.lastSuccess))\nNext discovery: \(time(s.nextDiscovery))\nConsecutive failures: \(s.failures)", width: width, style: 3)
        case .slack(let s):
            commands = "p: pause/resume polling   i: interval   r: retry now"
            if let error = s.lastError { lines += section("POLLING ERROR", error, width: width, style: 6) }
            lines += section("PROJECT ROUTING", s.repository.isEmpty ? "Automatically infer the project from conversation context and known tasks. Ask only when the context remains ambiguous." : s.repository, width: width)
            lines += section("SCHEDULE", "\(s.enabled ? "Enabled" : "Paused") · every \(s.intervalSeconds)s\nLast success: \(time(s.lastSuccess))\nNext poll: \(s.enabled ? time(s.nextPoll) : "paused")\nConsecutive failures: \(s.failures)", width: width, style: 3)
        case .github(let s):
            commands = "p: pause/resume polling   i: interval   r: retry now   n: add repository"
            if let error = s.lastError { lines += section("POLLING ERROR", error, width: width, style: 6) }
            lines += section("SCOPE", "Open PRs authored by \(s.author)\nLocal checkout: \(s.localRepository)", width: width)
            lines += section("SCHEDULE", "\(s.enabled ? "Enabled" : "Paused") · every \(s.intervalSeconds)s\nLast success: \(time(s.lastSuccess))\nNext poll: \(s.enabled ? time(s.nextPoll) : "paused")\nConsecutive failures: \(s.failures)", width: width, style: 3)
        }
        if c.hasError { lines += section("WHAT TO DO", "Check the reported scope/authentication or repository error. Retry with r after fixing it. Network errors also retry automatically with backoff. Slack credentials can be updated using slack-connect; GitHub uses your existing gh login.", width: width, style: 4) }
        return Detail(title: c.title(names: slackNames).trimmingCharacters(in: .whitespaces), subtitle: c.subtitle, commands: commands, lines: lines)
    }
    private func helpDetail(width: Int) -> Detail {
        let text = """
        1 Home: Needs you + work + detail
        4 Usage: tokens and API-equivalent cost by role and model
        Activity: C clears processed history, d hides one message, U restores hidden history
        2 Activity: incoming messages and decisions
        3 Connections: monitoring health and settings

        j / k       Move in the focused list; scroll detail when focused
        h / l       Focus the list / detail
        Ctrl-W h/l  Switch left / right pane
        Ctrl-W j/k  Move between Needs you and Work on Home
        Ctrl-W w    Cycle panes (Tab also cycles)
        Ctrl-D/U    Scroll the focused pane half a screen down / up
        Ctrl-F/B    Scroll the focused pane a full screen
        gg / G      First / last list item; top / latest detail

        Needs you shows source clarifications, child questions, reply drafts,
        approvals, failed children, and persistent connection problems.
        Select an item: its available actions are shown above its details.

        Enter / a   Answer a selected question
        c           Copy a selected suggested reply
        d           Mark a selected reply as replied (does not send)
        x           Dismiss a reply / ignore a source / reject a proposal
        a           Approve a selected proposal (records decision only)
        o           Inspect the linked child from Needs you

        n           New task; on Connections, add a GitHub repository
        M           Toggle CODEX / MOCK for new manual tasks
        s           Simulate a source message (Home or Activity)
        i           Task info: origin, connection messages, decision history
        C           Preview explicit worktree cleanup; y confirms and archives
        o           Open child in tmux: editor, shared Codex, shell
        m / p / t   Message / pause / exclusive terminal for a selected child
        d / x / r   Remove / cancel / retry a selected child
        u / i       Reconsider an ignored source / start independent exploration

        Input: Enter submits · Ctrl-N newline · Ctrl-U clear · Ctrl-W delete word
        Esc cancels input or returns Home. q detaches; workers keep running.
        """
        return Detail(title: "Keyboard guide", subtitle: "Navigation is separate from actions; available actions follow your selection", commands: "? / Esc: close guide   j/k or Ctrl-D/U: scroll", lines: TerminalText.wrap(text, width: width).map { Line($0) })
    }
    private func draw() {
        tm_terminal_clear()
        let rows = Int(tm_terminal_rows()), columns = Int(tm_terminal_columns())
        guard rows >= 22, columns >= 80 else {
            put(0, 0, "Resize to at least 80 × 22. q detaches; workers continue.", columns, 4)
            tm_terminal_refresh(); return
        }
        let leftWidth = min(46, max(28, columns / 3)), right = leftWidth + 3, width = columns - right - 2
        let bottom = rows - (composer == nil ? 5 : 10)
        let live = CoordinatorLock.isRunning(stateDirectory: stateDirectory)
        put(0, 1, "TASK MANAGER", 17, 1)
        put(0, 19, live ? "coordinator running" : "COORDINATOR OFFLINE", 25, live ? 5 : 6)
        put(0, max(46, columns - 30), "new: \(kind.rawValue.uppercased())  M changes runtime", 29, 3)
        let answers = attention.filter { if case .sourceQuestion = $0 { return true }; if case .workerQuestion = $0 { return true }; return false }.count
        let replies = attention.filter { if case .reply = $0 { return true }; return false }.count
        let active = tasks.filter { $0.status == .running || $0.status == .queued }.count
        put(1, 1, attention.isEmpty ? "All caught up  ·  \(active) active children" : "\(attention.count) \(attention.count == 1 ? "ITEM NEEDS" : "ITEMS NEED") YOU  ·  \(answers) \(answers == 1 ? "question" : "questions")  ·  \(replies) \(replies == 1 ? "reply" : "replies") ready  ·  \(active) active", columns - 2, attention.isEmpty ? 5 : 4)
        let home = page == .home ? "[1 Home]" : "1 Home", activity = page == .activity ? "[2 Activity]" : "2 Activity", settings = page == .connections || page == .repositories ? "[3 Connections]" : "3 Connections"
        let usage = page == .usage ? "[4 Usage]" : "4 Usage"
        put(2, 1, "\(home)     \(activity)     \(settings)     \(usage)     ? Help", columns - 2, 1)
        put(3, 1, UsagePresentation.compact(usageReport), columns - 2, 3)
        for row in 4...bottom { put(row, leftWidth + 1, "│", 1, navigation.focus == .detail ? 1 : 7) }
        if page == .home { drawHomeLists(width: leftWidth, bottom: bottom) }
        else { drawSecondaryList(width: leftWidth, bottom: bottom) }
        let content = detail(width: width)
        put(4, right, content.title, width, navigation.focus == .detail ? 8 : 1)
        put(5, right, single(content.subtitle), width, 3)
        for (offset, command) in TerminalText.wrap(content.commands, width: width).prefix(2).enumerated() {
            put(6 + offset, right, command, width, page == .home && navigation.detailSource == .attention && selectedAttention != nil ? 4 : 1)
        }
        put(8, right, String(repeating: "─", count: width), width, 7)
        let height = max(1, bottom - 9 + 1)
        navigation.viewport.update(count: content.lines.count, height: height)
        for (offset, line) in content.lines.dropFirst(navigation.viewport.offset).prefix(height).enumerated() { put(9 + offset, right, line.text, width, line.style) }
        if content.lines.count > height { put(bottom + 1, right, "Lines \(navigation.viewport.offset + 1)–\(min(content.lines.count, navigation.viewport.offset + height))/\(content.lines.count) · l focuses detail · Ctrl-U/D · gg/G", width, 3) }
        drawFooter(rows: rows, columns: columns)
        tm_terminal_refresh()
    }
    private func drawHomeLists(width: Int, bottom: Int) {
        let body = bottom - 4 + 1
        let attentionHeight = attention.isEmpty ? 4 : min(max(5, body / 2), body - 5)
        let workTop = 4 + attentionHeight + 1
        navigation.listCapacities[.attention] = max(1, (attentionHeight - 1) / 2)
        navigation.listCapacities[.work] = max(1, (bottom - workTop) / 2)
        put(4, 1, "\(navigation.focus == .attention ? "> " : "")NEEDS YOU [\(attention.count)]", width - 1, attention.isEmpty ? 3 : 4)
        if attention.isEmpty { put(6, 2, "No decisions waiting", width - 3, 3) }
        else {
            let capacity = max(1, (attentionHeight - 1) / 2), selected = attention.firstIndex { $0.id == selectedAttentionID } ?? 0
            let first = max(0, selected - capacity + 1)
            for (offset, item) in attention.dropFirst(first).prefix(capacity).enumerated() {
                let y = 5 + offset * 2, selected = item.id == selectedAttentionID
                put(y, 1, "\(selected ? ">" : " ") \(single(item.title))", width - 1, selected ? (navigation.focus == .attention ? 2 : 8) : 0)
                put(y + 1, 3, item.label + " · " + single(item.subtitle), width - 3, item.isFailure ? 6 : 4)
            }
        }
        put(workTop - 1, 1, String(repeating: "─", count: width - 1), width - 1, 7)
        put(workTop, 1, "\(navigation.focus == .work ? "> " : "")WORK [\(tasks.count)]", width - 1, navigation.focus == .work ? 1 : 3)
        if tasks.isEmpty { put(workTop + 2, 2, "n creates a new task", width - 3, 3); return }
        let capacity = max(1, (bottom - workTop) / 2), selected = tasks.firstIndex { $0.id == selectedTaskID } ?? 0, first = max(0, selected - capacity + 1)
        for (offset, task) in tasks.dropFirst(first).prefix(capacity).enumerated() {
            let y = workTop + 1 + offset * 2, selected = task.id == selectedTaskID
            put(y, 1, "\(selected ? ">" : " ") \(single(task.goal))", width - 1, selected ? (navigation.focus == .work ? 2 : 8) : 0)
            let reply = actions.contains { $0.taskID == task.id && $0.status == "open" }
            put(y + 1, 3, reply ? "Reply ready · Needs you" : taskStatus(task.status), width - 3, reply || task.status == .waitingForUser ? 4 : task.status == .failed ? 6 : task.status == .running ? 5 : 3)
        }
    }
    private func drawSecondaryList(width: Int, bottom: Int) {
        let entries: [(String, String, String, Bool)]
        let selected: String?
        let title: String
        switch page {
        case .usage:
            title = "USAGE BY ROLE"; selected = String(usageIndex)
            entries = UsagePresentation.roles.enumerated().map { index, role in
                (String(index), role.1, UsagePresentation.compact(usageReport.forRole(role.0)), false)
            }
        case .activity:
            title = "INCOMING ACTIVITY · C clear · U restore"
            selected = selectedSourceID.map(String.init)
            entries = sources.map { (String($0.id), "#\($0.id) " + single(slackNames.preview(of: $0)), sourceSummary($0) + " · " + sourceStatus($0.disposition), $0.disposition == .failed || $0.disposition == .waitingForUser) }
        case .connections:
            title = "SOURCE HEALTH"; selected = selectedConnectionID
            entries = connections.map { ($0.id, $0.title(names: slackNames), $0.subtitle, $0.hasError) }
        case .repositories:
            title = "ADD GITHUB REPOSITORY"; selected = String(repositoryIndex)
            entries = repositoryIndices.enumerated().map { offset, index in
                let candidate = discovery!.repositories[index]
                return (String(offset), candidate.slug, discovery?.current?.slug.lowercased() == candidate.slug.lowercased() ? "Current checkout" : "Available repository", false)
            }
        case .home: return
        }
        navigation.listCapacities[.work] = max(1, (bottom - 4) / 2)
        put(4, 1, title, width - 1, navigation.focus == .work ? 1 : 3)
        if entries.isEmpty { put(6, 2, discoveryJob != nil && page == .repositories ? "Discovering…" : "Nothing here yet", width - 3, 3); return }
        let capacity = max(1, (bottom - 4) / 2), index = entries.firstIndex { $0.0 == selected } ?? 0, first = max(0, index - capacity + 1)
        for (offset, entry) in entries.dropFirst(first).prefix(capacity).enumerated() {
            let y = 5 + offset * 2, chosen = entry.0 == selected
            put(y, 1, "\(chosen ? ">" : " ") \(single(entry.1))", width - 1, chosen ? (navigation.focus == .work ? 2 : 8) : 0)
            put(y + 1, 3, single(entry.2), width - 3, entry.3 ? 6 : 3)
        }
    }
    private func drawFooter(rows: Int, columns: Int) {
        if let composer {
            put(rows - 8, 1, String(repeating: "─", count: columns - 2), columns - 2, 7)
            put(rows - 7, 1, composer.title + " · Enter submits · Esc cancels", columns - 2, 4)
            let lines = TerminalText.wrap(String(decoding: input, as: UTF8.self) + "▏", width: columns - 3)
            for (offset, line) in lines.suffix(5).enumerated() { put(rows - 6 + offset, 1, line, columns - 2) }
            put(rows - 1, 1, notice.hasPrefix("Error:") ? notice : "Ctrl-N newline · Ctrl-U clear input · Ctrl-W delete word · Enter submit · Esc cancel", columns - 2, notice.hasPrefix("Error:") ? 6 : 3)
        } else {
            put(rows - 3, 1, String(repeating: "─", count: columns - 2), columns - 2, 7)
            put(rows - 2, 1, notice, columns - 2, notice.hasPrefix("Error:") ? 6 : 3)
            put(rows - 1, 1, "j/k move · h/l panes · Ctrl-W h/j/k/l · Ctrl-U/D scroll · gg/G · 1 Home  2 Activity  3 Connections  4 Usage · ? help · q detach", columns - 2, 3)
        }
    }
    private func put(_ row: Int, _ column: Int, _ text: String, _ width: Int, _ style: Int32 = 0) {
        tm_terminal_draw(Int32(row), Int32(column), single(text), Int32(max(0, width)), style)
    }
}
