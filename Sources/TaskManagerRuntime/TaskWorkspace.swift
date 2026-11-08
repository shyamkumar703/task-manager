import CLocalSupport
import Darwin
import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence

/// Published only after the coordinator is subscribed to this exact live thread.
public struct TaskWorkspace: Codable, Sendable, Equatable {
    public let taskID: String
    public let threadID: String
    public let workspace: String
    public let address: String

    public init(taskID: String, threadID: String, workspace: String, address: String) {
        self.taskID = taskID; self.threadID = threadID; self.workspace = workspace; self.address = address
    }

    static func file(taskID: String, stateDirectory: String) -> URL {
        URL(fileURLWithPath: stateDirectory).appendingPathComponent("live-agents").appendingPathComponent(taskID + ".json")
    }
    func save(stateDirectory: String) throws {
        let file = Self.file(taskID: taskID, stateDirectory: stateDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
    static func remove(taskID: String, stateDirectory: String) {
        try? FileManager.default.removeItem(at: file(taskID: taskID, stateDirectory: stateDirectory))
    }

    public static func load(store: Store, taskID: String, stateDirectory: String) async throws -> Self {
        let task = try await store.task(taskID)
        guard task.archivedAt == nil, ![.paused, .cancelled, .failed].contains(task.status),
              let session = try await store.agentSession(taskID: taskID), session.kind == .codex, !session.manualActive else {
            throw ManagerError.conflict("Open a running Codex task. Resume paused tasks first; mock tasks have no live agent.")
        }
        guard CoordinatorLock.isRunning(stateDirectory: stateDirectory),
              let data = try? Data(contentsOf: file(taskID: taskID, stateDirectory: stateDirectory)),
              let target = try? JSONDecoder().decode(Self.self, from: data),
              target.taskID == taskID, target.threadID == session.threadID, target.workspace == session.workspace,
              target.address.hasPrefix("unix:///tmp/task-agent-"),
              FileManager.default.fileExists(atPath: String(target.address.dropFirst("unix://".count))) else {
            throw ManagerError.conflict("The shared agent is not ready yet. Wait for startup, or use r to continue its saved thread.")
        }
        return target
    }

    public var workingDirectory: String {
        guard let path = realpath(workspace, nil) else { return workspace }
        defer { free(path) }
        return String(cString: path)
    }

    public var sessionName: String { "task-" + taskID.lowercased() }

    /// tmux executes multiple command arguments directly, without shell interpolation.
    public func codexArguments(executable: String) -> [String] {
        [executable, "resume", "--no-alt-screen", "--remote", address, "--cd", workingDirectory, threadID]
    }

    public static func executable(_ name: String) throws -> String {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw ManagerError.notFound("\(name) was not found on PATH")
    }

    static func hasTmuxSession(taskID: String) async -> Bool? {
        guard let tmux = try? executable("tmux") else { return false }
        do {
            let result = try await GHProcessRunner(executable: URL(fileURLWithPath: tmux), timeout: .seconds(2)).run(arguments: ["has-session", "-t", "=task-" + taskID.lowercased()])
            return result.exitCode == 0
        } catch { return nil } // A transient tmux failure does not revoke a live workspace.
    }

    public func prepareTmux(tmux: String? = nil) async throws -> String {
        let tmux = try tmux ?? Self.executable("tmux")
        let codex = try Self.executable("codex"), nvim = try Self.executable("nvim")
        let runner = GHProcessRunner(executable: URL(fileURLWithPath: tmux))
        func run(_ args: [String]) async throws -> String {
            let result = try await runner.run(arguments: args)
            guard result.exitCode == 0 else { throw ManagerError.invalid("tmux \(args.joined(separator: " ")) failed (exit \(result.exitCode))") }
            return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Search by our full task ID tag, rather than taking over an unrelated named session.
        let exists = try await runner.run(arguments: ["has-session", "-t", "=" + sessionName])
        var previous: String?
        if exists.exitCode == 0 {
            let tag = try await run(["show-options", "-qv", "-t", sessionName, "@task-manager-task"])
            guard tag == taskID else { throw ManagerError.conflict("A different tmux session already uses \(sessionName)") }
            previous = try await run(["show-options", "-qv", "-t", sessionName, "@task-manager-address"])
        } else {
            _ = try await run(["new-session", "-d", "-s", sessionName, "-n", "editor", "-c", workspace, nvim, "--"])
            _ = try await run(["set-option", "-t", sessionName, "@task-manager-task", taskID])
        }
        do {
            let names = Set(try await run(["list-windows", "-t", "=" + sessionName, "-F", "#{window_name}"]).split(separator: "\n").map(String.init))
            if !names.contains("editor") {
                let before = names.contains("codex") ? "codex" : "shell"
                _ = try await run(["new-window", "-d", "-b", "-t", "=" + sessionName + ":" + before, "-n", "editor", "-c", workspace, nvim, "--"])
            }
            if !names.contains("codex") {
                _ = try await run(["new-window", "-d", "-a", "-t", "=" + sessionName + ":editor", "-n", "codex", "-c", workspace] + codexArguments(executable: codex))
            } else {
                let dead = try await run(["display-message", "-p", "-t", "=" + sessionName + ":codex", "#{pane_dead}"])
                if previous != address || dead == "1" {
                    _ = try await run(["respawn-window", "-k", "-t", "=" + sessionName + ":codex", "-c", workspace] + codexArguments(executable: codex))
                }
            }
            _ = try await run(["set-window-option", "-t", "=" + sessionName + ":codex", "remain-on-exit", "on"])
            if !names.contains("shell") {
                let configured = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let shell = FileManager.default.isExecutableFile(atPath: configured) ? configured : "/bin/zsh"
                _ = try await run(["new-window", "-d", "-t", "=" + sessionName, "-n", "shell", "-c", workspace, shell, "-i"])
            }
        } catch {
            if exists.exitCode != 0 { _ = try? await run(["kill-session", "-t", "=" + sessionName]) }
            throw error
        }
        for window in ["editor", "codex", "shell"] {
            _ = try await run(["set-window-option", "-t", "=" + sessionName + ":" + window, "automatic-rename", "off"])
            _ = try await run(["set-window-option", "-t", "=" + sessionName + ":" + window, "allow-rename", "off"])
        }
        _ = try await run(["set-option", "-t", sessionName, "@task-manager-address", address])
        _ = try await run(["set-option", "-t", sessionName, "@task-manager-thread", threadID])
        _ = try await run(["select-window", "-t", "=" + sessionName + ":codex"])
        return sessionName
    }

    /// Switching clients preserves the manager's original tmux session. Outside tmux,
    /// attaching borrows the current TTY; detach returns to the dashboard.
    public static func focus(session: String) async throws {
        let executable = try executable("tmux")
        if ProcessInfo.processInfo.environment["TMUX"] != nil {
            let result = try await GHProcessRunner(executable: URL(fileURLWithPath: executable)).run(arguments: ["switch-client", "-t", "=" + session])
            guard result.exitCode == 0 else { throw ManagerError.invalid("tmux switch-client failed (\(result.exitCode))") }
            return
        }
        guard isatty(STDIN_FILENO) != 0 else { throw ManagerError.invalid("Attaching tmux requires an interactive terminal") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["attach-session", "-t", "=" + session]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        guard tm_terminal_give_foreground(process.processIdentifier) == 0 else {
            kill(process.processIdentifier, SIGKILL)
            throw ManagerError.invalid("Could not give tmux control of the terminal")
        }
        kill(-process.processIdentifier, SIGCONT)
        defer { tm_terminal_reclaim_foreground() }
        let status = await Task.detached { process.waitUntilExit(); return process.terminationStatus }.value
        guard status == 0 else { throw ManagerError.invalid("tmux attach exited with status \(status)") }
    }
}
