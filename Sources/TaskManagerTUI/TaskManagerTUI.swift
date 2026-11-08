import CLocalSupport
import Darwin
import Foundation
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime

@MainActor
public final class TaskManagerTUI {
    private enum Composer {
        case new, message(String), answer(String), source, sourceAnswer(Int64, Int), githubPath(String, String), githubInterval(String), githubFilter, slackProject(SlackDiscoveredConversation), slackInterval(String), slackFilter
        var title: String {
            switch self {
            case .slackProject(let item): "Local project for " + item.conversation.name
            case .slackInterval: "Slack poll interval in seconds (10...86400)"
            case .slackFilter: "Filter Slack conversations"
            case .githubPath(let slug, _): "Local checkout path for " + slug
            case .githubFilter: "Filter repositories by name"
            case .githubInterval: "Poll interval in seconds (10...86400)"
            case .new: "New task goal"
            case .message: "Follow-up to selected child"
            case .answer: "Answer pending question"
            case .source: "Incoming source message · real master decides destination"
            case .sourceAnswer: "Answer master clarification"
            }
        }
    }
    private let store: Store
    private let stateDirectory: String
    private let repository: String
    private let executable: URL
    private var daemon: Process?
    private var tasks: [ManagedTask] = []
    private var questions: [Question] = []
    private var sources: [IncomingSource] = []
    private var selectedSourceID: Int64?
    private var showingSources = false
    private var showingGitHub = false
    private var showingSlack = false
    private var slackSources: [SlackSource] = []
    private var slackWorkspaces: [SlackWorkspace] = []
    private var selectedSlackID: String?
    private var pickingSlack = false
    private var slackDiscovery: [SlackDiscoveredConversation] = []
    private var slackDiscoveryJob: Task<Void, Never>?
    private var slackIndex = 0
    private var slackFilter = ""
    private var slackIndices: [Int] {
        slackDiscovery.indices.filter { slackFilter.isEmpty || (slackDiscovery[$0].connection.workspaceName + " " + slackDiscovery[$0].conversation.name).localizedCaseInsensitiveContains(slackFilter) }
    }
    private var githubSources: [GitHubSource] = []
    private var selectedGitHubID: String?
    private var pickingGitHub = false
    private var discovery: GitHubDiscoveryResult?
    private var discoveryJob: Task<Void, Never>?
    private var discoveredIndex = 0
    private var discoveryFilter = ""
    private var discoveryIndices: [Int] {
        guard let discovery else { return [] }
        return discovery.repositories.indices.filter { discoveryFilter.isEmpty || discovery.repositories[$0].slug.localizedCaseInsensitiveContains(discoveryFilter) }
    }
    private var session: AgentSessionRecord?
    private var output: [AgentOutput] = []
    private var messages: [TaskMessage] = []
    private var selectedID: String?
    private var kind: WorkerKind = .codex
    private var composer: Composer?
    private var input = Data()
    private var scroll = 0
    private var notice = "Press n to create a real Codex task; Tab selects mock mode."
    private var running = true

    public init(store: Store, stateDirectory: String, repository: String, executable: URL) {
        self.store = store
        self.stateDirectory = stateDirectory
        self.repository = repository
        self.executable = executable
    }

    public func run() async throws {
        guard tm_terminal_open() == 0 else { throw ManagerError.invalid("The TUI requires an interactive terminal (TTY)") }
        defer { discoveryJob?.cancel(); slackDiscoveryJob?.cancel(); tm_terminal_close() }
        let previous = signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { self.running = false }
        termination.resume()
        defer { termination.cancel(); signal(SIGTERM, previous) }
        notice = "Starting or updating the coordinator…"
        draw()
        try await store.registerProject(repository: repository)
        daemon = try await Daemon.start(executable: executable, stateDirectory: stateDirectory)
        notice = "Press n for a task, s to inject a source message, or e to inspect triage."
        var refreshed = ContinuousClock.now.advanced(by: .seconds(-1))
        while running {
            if refreshed.duration(to: .now) >= .milliseconds(250) {
                do { try await reload() }
                catch { notice = "Error: \(error)" }
                refreshed = .now
            }
            draw()
            for _ in 0..<64 {
                let key = tm_terminal_key()
                if key < 0 { break }
                do { try await handle(key) }
                catch { notice = "Error: \(error)" }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private func reload() async throws {
        slackSources = try await store.slackSources()
        slackWorkspaces = try await store.slackWorkspaces()
        if !slackSources.contains(where: { $0.id == selectedSlackID }) { selectedSlackID = slackSources.first?.id }
        githubSources = try await store.gitHubSources()
        if !githubSources.contains(where: { $0.id == selectedGitHubID }) { selectedGitHubID = githubSources.first?.id }
        tasks = try await store.tasks()
        questions = try await store.questions()
        sources = try await store.sources()
        if selectedSourceID == nil || !sources.contains(where: { $0.id == selectedSourceID }) { selectedSourceID = sources.first?.id }
        if selectedID == nil || !tasks.contains(where: { $0.id == selectedID }) { selectedID = tasks.first?.id }
        if let id = selectedID {
            session = try await store.agentSession(taskID: id)
            output = try await store.outputs(taskID: id)
            messages = try await store.messages(taskID: id)
        } else { session = nil; output = []; messages = [] }
    }

    private func handle(_ key: Int32) async throws {
        if let composer {
            switch key {
            case 27: self.composer = nil; input = Data(); notice = "Input cancelled"
            case 10, 13, 343:
                let text = String(decoding: input, as: UTF8.self)
                try requireText(text, name: "Input")
                switch composer {
                case .slackProject(let item):
                    selectedSlackID = try await store.addSlackSource(workspaceID: item.connection.workspaceID, workspaceName: item.connection.workspaceName, userID: item.connection.userID, channelID: item.conversation.id, channelName: item.conversation.name, repository: text)
                    pickingSlack = false
                    notice = "Slack conversation enabled; first poll baselines history, then new messages enter triage"
                case .slackInterval(let id):
                    guard let seconds = Int(text) else { throw ManagerError.invalid("Interval must be seconds") }
                    try await store.setSlackSourceInterval(id, seconds: seconds)
                    notice = "Slack polling interval saved"
                case .slackFilter: slackFilter = text; slackIndex = 0
                case .githubFilter:
                    discoveryFilter = text; discoveredIndex = 0
                case .githubPath(let slug, let login):
                    let discovered = try await GitHubDiscovery().checkoutRepository(text)
                    guard discovered?.slug.lowercased() == slug.lowercased() else { throw ManagerError.invalid("This checkout's origin does not match " + slug) }
                    selectedGitHubID = try await store.addGitHubSource(repository: slug, localRepository: text, author: login)
                    pickingGitHub = false
                    notice = "Repository enabled; polling every 60 seconds using your gh identity"
                case .githubInterval(let id):
                    guard let seconds = Int(text) else { throw ManagerError.invalid("Interval must be seconds") }
                    try await store.setGitHubSourceInterval(id, seconds: seconds)
                    notice = "Polling interval saved"
                case .new:
                    let task = try await store.createAgentTask(goal: text, repository: repository, kind: kind)
                    selectedID = task.id
                    notice = "\(kind.rawValue.capitalized) task queued"
                    showingSources = false
                case .source:
                    selectedSourceID = try await store.injectSource(body: text, repository: repository, workerKind: kind)
                    showingSources = true
                    notice = "Source message saved; master triage will choose what happens next"
                case .sourceAnswer(let id, let attempt):
                    try await store.answerSource(eventID: id, text: text, expectedAttempt: attempt)
                    notice = "Clarification saved; master will reconsider the event"
                case .message(let id):
                    _ = try await store.addMessage(taskID: id, body: text)
                    notice = "Follow-up saved; delivery status appears in the conversation"
                case .answer(let id):
                    try await store.answer(questionID: id, text: text)
                    notice = "Answer saved; child will continue"
                }
                self.composer = nil; input = Data(); scroll = 0
                try await reload()
            case 14: input.append(10) // Ctrl-N inserts a newline; Enter sends.
            case 8, 127:
                var text = String(decoding: input, as: UTF8.self)
                if !text.isEmpty { text.removeLast() }
                input = Data(text.utf8)
            default:
                if key == tm_key_backspace() {
                    var text = String(decoding: input, as: UTF8.self)
                    if !text.isEmpty { text.removeLast() }
                    input = Data(text.utf8)
                } else if (32...255).contains(key), input.count < 32768 { input.append(UInt8(key)) }
            }
            return
        }
        if key == tm_key_up() || key == 107 { select(-1); return }
        if key == tm_key_down() || key == 106 { select(1); return }
        if key == tm_key_page_up() { scroll += max(1, Int(tm_terminal_rows()) - 12); return }
        if key == tm_key_page_down() { scroll = max(0, scroll - max(1, Int(tm_terminal_rows()) - 12)); return }
        if key == 108 {
            showingSlack.toggle(); showingGitHub = false; showingSources = false
            discoveryJob?.cancel(); pickingSlack = false; slackDiscoveryJob?.cancel(); scroll = 0
            return
        }
        if key == 103 && showingSlack { showingSlack = false; showingGitHub = true; pickingSlack = false; slackDiscoveryJob?.cancel(); return }
        if showingSlack {
            if pickingSlack {
                switch key {
                case 113, 3: running = false
                case 27: pickingSlack = false; slackDiscoveryJob?.cancel()
                case 114: beginSlackDiscovery()
                case 47: composer = .slackFilter; input = Data()
                case 99: slackFilter = ""; slackIndex = 0
                case 10, 13, 343:
                    guard slackIndices.indices.contains(slackIndex) else { return }
                    let item = slackDiscovery[slackIndices[slackIndex]]
                    if let existing = slackSources.first(where: { $0.workspaceID == item.connection.workspaceID && $0.channelID == item.conversation.id }) {
                        selectedSlackID = existing.id; pickingSlack = false
                    } else { composer = .slackProject(item); input = Data(repository.utf8) }
                default: break
                }
            } else {
                switch key {
                case 113, 3: running = false
                case 110: beginSlackDiscovery()
                case 112:
                    if let source = slackSources.first(where: { $0.id == selectedSlackID }) {
                        try await store.setSlackSourceEnabled(source.id, enabled: !source.enabled); try await reload()
                    }
                case 105:
                    if let source = slackSources.first(where: { $0.id == selectedSlackID }) {
                        composer = .slackInterval(source.id); input = Data(String(source.intervalSeconds).utf8)
                    }
                case 101: showingSlack = false; showingSources = true
                default: break
                }
            }
            return
        }
        if key == 103 { showingSlack = false; showingGitHub.toggle(); showingSources = false; pickingGitHub = false; discoveryJob?.cancel(); scroll = 0; return }
        if showingGitHub {
            if pickingGitHub {
                switch key {
                case 113, 3: running = false
                case 27: pickingGitHub = false; discoveryJob?.cancel()
                case 114: beginGitHubDiscovery()
                case 47: composer = .githubFilter; input = Data()
                case 99: discoveryFilter = ""; discoveredIndex = 0
                case 10, 13, 343:
                    guard let discovery, discoveryIndices.indices.contains(discoveredIndex) else { return }
                    let selected = discovery.repositories[discoveryIndices[discoveredIndex]]
                    if let existing = githubSources.first(where: { $0.repository.caseInsensitiveCompare(selected.slug) == .orderedSame }) {
                        selectedGitHubID = existing.id; pickingGitHub = false
                        notice = "Already configured; p toggles polling and i changes the interval"
                        return
                    }
                    if discovery.current?.slug.lowercased() == selected.slug.lowercased() {
                        selectedGitHubID = try await store.addGitHubSource(repository: selected.slug, localRepository: repository, author: discovery.login)
                        pickingGitHub = false
                        notice = "Current checkout enabled; polling every 60 seconds using your gh identity"
                        try await reload()
                    } else {
                        composer = .githubPath(selected.slug, discovery.login); input = Data()
                    }
                default: break
                }
                return
            }
            switch key {
            case 113, 3: running = false
            case 110: beginGitHubDiscovery()
            case 105:
                if let source = githubSources.first(where: { $0.id == selectedGitHubID }) {
                    composer = .githubInterval(source.id); input = Data(String(source.intervalSeconds).utf8)
                }
            case 112:
                if let source = githubSources.first(where: { $0.id == selectedGitHubID }) {
                    try await store.setGitHubSourceEnabled(source.id, enabled: !source.enabled)
                    try await reload()
                }
            case 101: showingGitHub = false; showingSources = true
            default: break
            }
            return
        }
        if key == 101 { showingSources.toggle(); scroll = 0; return }
        if key == 115 { composer = .source; input = Data(); return }
        if showingSources, ![Int32(113), 3, 9, 110].contains(key) {
            guard let source = sources.first(where: { $0.id == selectedSourceID }) else { return }
            switch key {
            case 10, 13, 343:
                if let id = source.taskID {
                    guard tasks.contains(where: { $0.id == id }) else { notice = "Destination task is archived or unavailable; restore it to inspect it"; return }
                    selectedID = id; showingSources = false; scroll = 0
                    try await reload()
                } else { notice = "This source has no child task yet" }
            case 97:
                guard source.disposition == .waitingForUser else { notice = "No master question for this source"; return }
                composer = .sourceAnswer(source.id, source.attempts); input = Data()
            case 114: try await store.retrySource(source.id); try await reload(); notice = "Master triage queued for retry"
            case 117: try await store.unignoreSource(source.id); try await reload(); notice = "Source unignored; queued for master triage"
            case 120: try await store.ignoreSource(source.id); try await reload(); notice = "Source event ignored"
            default: notice = "Sources: Enter opens child · a answers master · r retries failure · u unignores · x ignores · e returns"
            }
            return
        }
        switch key {
        case 113, 3: running = false // q or Ctrl-C detaches; daemon and workers continue.
        case 9:
            kind = kind == .mock ? .codex : .mock
            notice = "New tasks use \(kind.rawValue). Existing tasks keep their runtime."
        case 110: composer = .new; input = Data()
        case 109:
            guard let id = selectedID else { return }
            composer = .message(id); input = Data()
        case 97:
            guard let question = questions.first(where: { $0.taskID == selectedID }) else { notice = "No pending question for this task"; return }
            composer = .answer(question.id); input = Data()
        case 112:
            guard let task = tasks.first(where: { $0.id == selectedID }) else { return }
            if task.status == .paused { try await store.resume(task.id); notice = "Task resumed" }
            else { try await store.transition(task.id, to: .paused); notice = "Pausing task…" }
            try await reload()
        case 116:
            guard let id = selectedID else { return }
            notice = "Pausing child and opening its worktree terminal…"
            draw()
            let handoff = try await ManualTerminal.prepare(store: store, taskID: id)
            tm_terminal_close()
            do {
                _ = try await ManualTerminal.runShell(session: handoff)
                try await store.releaseTerminal(taskID: id)
                notice = "Returned from terminal. Press p to resume a paused child."
            } catch {
                try? await store.releaseTerminal(taskID: id)
                notice = "Terminal error: \(error)"
            }
            tm_terminal_reclaim_foreground()
            guard tm_terminal_open() == 0 else { running = false; throw ManagerError.invalid("Could not restore terminal UI") }
            try await reload()
        case 100:
            guard let id = selectedID else { return }
            try await store.archive(id)
            notice = "Task removed from list; history and worktree retained."
            scroll = 0
            try await reload()
        case 120:
            guard let id = selectedID else { return }
            try await store.transition(id, to: .cancelled); notice = "Task cancelled; local work preserved"
            try await reload()
        case 114:
            guard let task = tasks.first(where: { $0.id == selectedID }) else { return }
            if task.status == .paused { try await store.resume(task.id) }
            else { try await store.transition(task.id, to: .queued) }
            notice = "Task queued to continue its saved thread"
            try await reload()
        default: break
        }
    }

    private func beginSlackDiscovery() {
        guard slackDiscoveryJob == nil else { return }
        pickingSlack = true; slackDiscovery = []; slackIndex = 0; slackFilter = ""
        notice = "Discovering Slack conversations using the saved Keychain connection…"
        slackDiscoveryJob = Task {
            defer { slackDiscoveryJob = nil }
            do {
                let result = try await SlackDiscovery.discover(stateDirectory: stateDirectory)
                try Task.checkCancellation()
                slackDiscovery = result
                notice = result.isEmpty ? "No conversations found. Connect with slack-connect and check user scopes." : "Select a conversation, then choose its local project"
            } catch {
                if !Task.isCancelled { notice = "Slack discovery failed: \(error). Press r to retry." }
            }
        }
    }

    private func beginGitHubDiscovery() {
        guard discoveryJob == nil else { return }
        pickingGitHub = true; discovery = nil; discoveredIndex = 0; discoveryFilter = ""
        notice = "Discovering repositories using your existing gh login…"
        discoveryJob = Task {
            defer { discoveryJob = nil }
            do {
                let result = try await GitHubDiscovery().discover(checkout: repository)
                try Task.checkCancellation()
                discovery = result
                notice = "Select a repository; Enter enables the current checkout or asks for its local path"
            } catch {
                if !Task.isCancelled { notice = "Discovery failed: \(error). Check gh auth status, then press r to retry." }
            }
        }
    }

    private func select(_ delta: Int) {
        if showingSlack {
            if pickingSlack { if !slackIndices.isEmpty { slackIndex = min(slackIndices.count - 1, max(0, slackIndex + delta)) } }
            else if !slackSources.isEmpty {
                let index = slackSources.firstIndex(where: { $0.id == selectedSlackID }) ?? 0
                selectedSlackID = slackSources[min(slackSources.count - 1, max(0, index + delta))].id
            }
            return
        }
        if showingGitHub && pickingGitHub {
            guard !discoveryIndices.isEmpty else { return }
            discoveredIndex = min(discoveryIndices.count - 1, max(0, discoveredIndex + delta))
            return
        }
        if showingGitHub {
            guard !githubSources.isEmpty else { return }
            let index = githubSources.firstIndex(where: { $0.id == selectedGitHubID }) ?? 0
            selectedGitHubID = githubSources[min(githubSources.count - 1, max(0, index + delta))].id
            return
        }
        if showingSources {
            guard !sources.isEmpty else { return }
            let index = sources.firstIndex(where: { $0.id == selectedSourceID }) ?? 0
            selectedSourceID = sources[min(sources.count - 1, max(0, index + delta))].id
            scroll = 0
            return
        }
        guard !tasks.isEmpty else { return }
        let index = tasks.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = tasks[min(tasks.count - 1, max(0, index + delta))].id
        scroll = 0
    }

    private func draw() {
        tm_terminal_clear()
        let rows = Int(tm_terminal_rows()), columns = Int(tm_terminal_columns())
        guard rows >= 16, columns >= 76 else {
            draw(0, 0, "Resize terminal to at least 76 × 16. q detaches.", width: columns)
            tm_terminal_refresh(); return
        }
        let left = min(36, columns / 3), right = left + 2, width = columns - right - 1
        let live = CoordinatorLock.isRunning(stateDirectory: stateDirectory)
        let masterQuestions = sources.filter { $0.disposition == .waitingForUser }.count
        let incoming = sources.filter { [.pending, .triaging, .failed].contains($0.disposition) }.count
        draw(0, 0, " TASK MANAGER   new: \(kind.rawValue.uppercased())   coordinator: \(live ? "running" : "offline")   asks: \(questions.count + masterQuestions)   inbox: \(incoming) ", width: columns, emphasis: 2)
        if showingSlack {
            drawSlack(rows: rows, columns: columns)
            drawFooter(rows: rows, columns: columns)
            tm_terminal_refresh()
            return
        }
        if showingGitHub {
            if pickingGitHub {
                draw(1, 1, "ADD GITHUB REPOSITORY · " + (discovery?.login ?? "detecting gh identity…"), width: columns - 2, emphasis: 1)
                if let discovery {
                    let capacity = max(1, rows - 8)
                    let first = max(0, discoveredIndex - capacity + 1)
                    for (offset, index) in discoveryIndices.dropFirst(first).prefix(capacity).enumerated() {
                        let candidate = discovery.repositories[index]
                        let current = candidate.slug.lowercased() == discovery.current?.slug.lowercased()
                        let configured = githubSources.contains { $0.repository.caseInsensitiveCompare(candidate.slug) == .orderedSame }
                        draw(3 + offset, 1, "\(first + offset == discoveredIndex ? ">" : " ") \(candidate.slug)\(current ? " · current checkout" : "")\(configured ? " · configured" : "")", width: columns - 2, emphasis: first + offset == discoveredIndex ? 2 : 0)
                    }
                    if discoveryIndices.isEmpty { draw(3, 1, "No matching repositories. Press c to clear the filter.", width: columns - 2) }
                }
                drawFooter(rows: rows, columns: columns)
                tm_terminal_refresh()
                return
            }
            draw(1, 1, "GITHUB REPOSITORIES", width: columns - 2, emphasis: 1)
            if githubSources.isEmpty { draw(3, 1, "Press n to discover repositories using your existing gh login.", width: columns - 2) }
            let selected = githubSources.firstIndex(where: { $0.id == selectedGitHubID }) ?? 0
            let capacity = max(1, (rows - 8) / 5)
            for (index, source) in githubSources.dropFirst(max(0, selected - capacity + 1)).prefix(capacity).enumerated() {
                let y = 3 + index * 5
                let success = source.lastSuccess.map { Date(timeIntervalSince1970: $0).formatted() } ?? "not yet"
                draw(y, 1, "\(source.id == selectedGitHubID ? ">" : " ") \(source.repository) · \(source.enabled ? "enabled" : "disabled") · every \(source.intervalSeconds)s", width: columns - 2, emphasis: source.id == selectedGitHubID ? 2 : 0)
                draw(y + 1, 3, "Open PRs by \(source.author) → \(source.localRepository)", width: columns - 4)
                let next = !source.enabled ? "disabled" : source.nextPoll == 0 ? "due now" : Date(timeIntervalSince1970: source.nextPoll).formatted()
                draw(y + 2, 3, "Last success: \(success) · next: \(next)", width: columns - 4)
                draw(y + 3, 3, source.lastError.map { "Error: " + $0 } ?? "First successful poll baselines history; later feedback enters the incoming view.", width: columns - 4)
            }
            drawFooter(rows: rows, columns: columns)
            tm_terminal_refresh()
            return
        }
        if showingSources {
            drawSources(rows: rows, columns: columns, left: left, right: right, width: width)
            drawFooter(rows: rows, columns: columns)
            tm_terminal_refresh()
            return
        }
        draw(1, 1, "TASKS (\(tasks.count))", width: left, emphasis: 1)
        let selected = tasks.firstIndex(where: { $0.id == selectedID }) ?? 0
        let available = max(1, (rows - 9) / 2)
        let first = max(0, selected - available + 1)
        for (offset, task) in tasks.dropFirst(first).prefix(available).enumerated() {
            let y = 3 + offset * 2
            let focused = task.id == selectedID
            draw(y, 1, "\(focused ? ">" : " ") \(task.goal)", width: left - 1, emphasis: focused ? 2 : 0)
            draw(y + 1, 3, task.status.rawValue, width: left - 3)
        }
        if let task = tasks.first(where: { $0.id == selectedID }) {
            draw(2, right, task.goal, width: width, emphasis: 1)
            draw(3, right, "\(task.status.rawValue) · \(session?.kind.rawValue ?? "unbound") · \(messages.filter { !$0.delivered }.count) pending messages", width: width)
            draw(4, right, "Workspace: \(session?.workspace ?? session?.repository ?? repository)", width: width)
            var lines: [String] = []
            if output.isEmpty { lines += ["Waiting for the coordinator…"] }
            for item in output {
                let text = item.kind == "assistant" ? TerminalText.assistantText(item.text) : item.text
                var label = item.kind.uppercased()
                if item.kind == "user", let message = messages.first(where: { "message-\($0.id)" == item.itemID }) {
                    label += message.delivered ? " · ACCEPTED" : " · QUEUED"
                }
                lines += [label] + TerminalText.wrap(text, width: width) + [""]
            }
            if let question = questions.first(where: { $0.taskID == task.id }) {
                lines += TerminalText.wrap("QUESTION — \(question.prompt)  [a to answer]", width: width)
            }
            let visible = rows - 12
            let end = max(0, lines.count - scroll)
            let start = max(0, end - visible)
            for (offset, line) in lines[start..<end].enumerated() { draw(6 + offset, right, line, width: width) }
        } else {
            draw(3, right, "Create a task with n. No GitHub source is required.", width: width)
            draw(5, right, "CODEX executes tasks in isolated git worktrees.", width: width)
            draw(6, right, "Tab selects MOCK for simulated interaction tests.", width: width)
        }
        drawFooter(rows: rows, columns: columns)
        tm_terminal_refresh()
    }

    private func drawSlack(rows: Int, columns: Int) {
        draw(1, 1, pickingSlack ? "ADD SLACK CONVERSATION" : "SLACK CONVERSATIONS", width: columns - 2, emphasis: 1)
        if pickingSlack {
            let capacity = max(1, rows - 8), first = max(0, slackIndex - capacity + 1)
            for (offset, index) in slackIndices.dropFirst(first).prefix(capacity).enumerated() {
                let item = slackDiscovery[index]
                let configured = slackSources.contains { $0.workspaceID == item.connection.workspaceID && $0.channelID == item.conversation.id }
                draw(3 + offset, 1, "\(first + offset == slackIndex ? ">" : " ") \(item.connection.workspaceName) / \(item.conversation.name)\(configured ? " · configured" : "")", width: columns - 2, emphasis: first + offset == slackIndex ? 2 : 0)
            }
            if slackIndices.isEmpty { draw(3, 1, slackDiscoveryJob == nil ? "No matching conversations. c clears the filter; r retries discovery." : "Discovering conversations…", width: columns - 2) }
            return
        }
        if slackSources.isEmpty {
            let error = slackWorkspaces.compactMap(\.lastError).first
            draw(3, 1, error.map { "Discovery error: " + $0 } ?? "Connected workspaces are monitored automatically. Discovering accessible conversations…", width: columns - 2)
        }
        draw(2, 1, "Automatic monitoring · \(slackWorkspaces.count) workspaces · \(slackSources.count) conversations", width: columns - 2)
        let selected = slackSources.firstIndex(where: { $0.id == selectedSlackID }) ?? 0
        let capacity = max(1, (rows - 8) / 5)
        for (index, source) in slackSources.dropFirst(max(0, selected - capacity + 1)).prefix(capacity).enumerated() {
            let y = 3 + index * 5
            let success = source.lastSuccess.map { Date(timeIntervalSince1970: $0).formatted() } ?? "not yet"
            let next = !source.enabled ? "disabled" : source.nextPoll == 0 ? "due now" : Date(timeIntervalSince1970: source.nextPoll).formatted()
            draw(y, 1, "\(source.id == selectedSlackID ? ">" : " ") \(source.workspaceName) / \(source.channelName) · \(source.enabled ? "enabled" : "disabled") · every \(source.intervalSeconds)s", width: columns - 2, emphasis: source.id == selectedSlackID ? 2 : 0)
            draw(y + 1, 3, "Project: " + (source.repository.isEmpty ? "Automatic task matching; questions for unclear projects" : source.repository), width: columns - 4)
            draw(y + 2, 3, "Last success: \(success) · next: \(next)", width: columns - 4)
            draw(y + 3, 3, source.lastError.map { "Error: " + $0 } ?? "New messages, edits, and thread replies enter triage; initial history is baselined.", width: columns - 4)
        }
    }

    private func drawSources(rows: Int, columns: Int, left: Int, right: Int, width: Int) {
        draw(1, 1, "INCOMING (\(sources.count))", width: left, emphasis: 1)
        let selected = sources.firstIndex(where: { $0.id == selectedSourceID }) ?? 0
        let available = max(1, (rows - 9) / 2)
        let first = max(0, selected - available + 1)
        for (offset, event) in sources.dropFirst(first).prefix(available).enumerated() {
            let focused = event.id == selectedSourceID
            let y = 3 + offset * 2
            draw(y, 1, "\(focused ? ">" : " ") #\(event.id) \(event.body.replacingOccurrences(of: "\n", with: " "))", width: left - 1, emphasis: focused ? 2 : 0)
            draw(y + 1, 3, event.disposition.rawValue, width: left - 3)
        }
        guard let event = sources.first(where: { $0.id == selectedSourceID }) else {
            draw(3, right, "Press s to inject a source message.", width: width)
            draw(5, right, "The real master judges relevance across this repo's tasks.", width: width)
            return
        }
        draw(2, right, "Source #\(event.id) · \(event.integration) · \(event.disposition.rawValue)", width: width, emphasis: 1)
        let runtime = event.targetWorkerKind.map { "Child runtime: \($0.rawValue.uppercased())" } ?? "New work uses \(event.workerKind.rawValue.uppercased())"
        draw(3, right, runtime + " · master uses Codex", width: width)
        var lines = ["SOURCE MESSAGE"] + TerminalText.wrap(event.body, width: width) + [""]
        if let reason = event.reason { lines += ["DECISION"] + TerminalText.wrap(reason, width: width) + [""] }
        if let id = event.taskID {
            let goal = tasks.first(where: { $0.id == id })?.goal ?? id
            lines += TerminalText.wrap("CHILD: \(goal)", width: width)
            if let delivered = event.messageDelivered { lines += [delivered ? "MESSAGE ACCEPTED by child" : "MESSAGE QUEUED for child"] }
            lines += ["Enter opens the child task.", ""]
        }
        if let error = event.lastError { lines += ["TRIAGE ERROR"] + TerminalText.wrap(error, width: width) + [""] }
        if let answer = event.clarification { lines += ["YOUR CLARIFICATION"] + TerminalText.wrap(answer, width: width) + [""] }
        if let question = event.question { lines += ["MASTER QUESTION — press a to answer"] + TerminalText.wrap(question, width: width) }
        let end = max(0, lines.count - scroll)
        let start = max(0, end - (rows - 11))
        for (offset, line) in lines[start..<end].enumerated() { draw(5 + offset, right, line, width: width) }
    }

    private func drawFooter(rows: Int, columns: Int) {
        draw(rows - 5, 0, String(repeating: "─", count: columns), width: columns)
        if let composer {
            draw(rows - 4, 1, "\(composer.title) · Enter sends · Ctrl-N newline · Esc cancels", width: columns - 2, emphasis: 1)
            let lines = TerminalText.wrap(String(decoding: input, as: UTF8.self) + "▏", width: columns - 2)
            for (offset, line) in lines.suffix(2).enumerated() { draw(rows - 3 + offset, 1, line, width: columns - 2) }
        } else {
            draw(rows - 4, 1, notice, width: columns - 2)
            if showingSlack {
                draw(rows - 3, 1, pickingSlack ? "↑↓ select · Enter add · / filter · c clear · r refresh · Esc back" : "p pause/resume conversation · i interval · ↑↓ select (discovery is automatic)", width: columns - 2)
                draw(rows - 2, 1, "l tasks · g GitHub · e incoming · q detach (polling continues)", width: columns - 2)
            } else if showingGitHub && pickingGitHub {
                draw(rows - 3, 1, "↑↓ select · Enter add (60s default) · / filter · c clear · r refresh · Esc back", width: columns - 2)
                draw(rows - 2, 1, "Current checkout is inferred from origin; other repos need a local path · q detach", width: columns - 2)
            } else if showingGitHub {
                draw(rows - 3, 1, "n discover/add · p enable/disable · i interval · ↑↓ select", width: columns - 2)
                draw(rows - 2, 1, "l Slack · g tasks · e incoming · q detach (polling continues)", width: columns - 2)
            } else if showingSources {
                draw(rows - 3, 1, "s inject source · a clarify · Enter open child · r retry · u unignore · x ignore", width: columns - 2)
                draw(rows - 2, 1, "l Slack · g GitHub · e tasks · ↑↓ select · PgUp/Dn scroll · Tab new-worker runtime · q detach", width: columns - 2)
            } else {
                draw(rows - 3, 1, "n new · m msg · a answer · p pause · t terminal · d remove · s source", width: columns - 2)
                draw(rows - 2, 1, "l Slack · g GitHub · e incoming · r retry · x cancel · Tab runtime · ↑↓ select · PgUp/Dn · q quit", width: columns - 2)
            }
        }
    }

    private func draw(_ row: Int, _ column: Int, _ text: String, width: Int, emphasis: Int32 = 0) {
        tm_terminal_draw(Int32(row), Int32(column), TerminalText.clean(text), Int32(width), emphasis)
    }
}
