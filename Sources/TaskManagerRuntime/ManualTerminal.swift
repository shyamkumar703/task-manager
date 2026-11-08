import Darwin
import CLocalSupport
import Foundation
import TaskManagerCore
import TaskManagerPersistence

public enum ManualTerminal {
    /// Reserve the worktree, pause its worker, and wait until the coordinator has closed the runtime.
    public static func prepare(store: Store, taskID: String, timeout: Duration = .seconds(15)) async throws -> AgentSessionRecord {
        guard let existing = try await store.agentSession(taskID: taskID), let path = existing.workspace else {
            throw ManagerError.conflict("This task has no worktree yet. Mock tasks do not create worktrees.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw ManagerError.notFound("Worktree is missing: \(path)")
        }
        _ = try await store.claimTerminal(taskID: taskID)
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard try await store.task(taskID).archivedAt == nil else { throw ManagerError.conflict("Task was archived") }
                if let session = try await store.agentSession(taskID: taskID), !session.workerActive, session.turnID == nil {
                    return session
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ManagerError.conflict("The child is still stopping. Try opening the terminal again after it pauses.")
        } catch {
            try? await store.releaseTerminal(taskID: taskID)
            throw error
        }
    }

    public static func environment(for session: AgentSessionRecord, inheriting base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment["TASK_MANAGER_TASK_ID"] = session.taskID
        environment["TASK_MANAGER_WORKTREE"] = session.workspace
        environment["TASK_MANAGER_CODEX_THREAD_ID"] = session.threadID
        return environment
    }

    /// Uses the existing terminal and shell configuration. No command is built from a worktree path.
    public static func runShell(session: AgentSessionRecord) async throws -> Int32 {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            throw ManagerError.invalid("Opening a task terminal requires an interactive TTY")
        }
        guard let workspace = session.workspace else { throw ManagerError.notFound("No worktree assigned") }
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shell = configured.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: configured) ? configured : "/bin/zsh"
        print("\nTask worktree: \(workspace)")
        print("Commit or push manually here. Type exit to return to the task manager.")
        if let thread = session.threadID {
            print("To continue the saved agent interactively: codex resume \(thread)")
        }
        print("The background worker is paused while this terminal owns the task.\n")
        fflush(stdout)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-i"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspace)
        process.environment = environment(for: session)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        guard tm_terminal_give_foreground(process.processIdentifier) == 0 else {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw ManagerError.invalid("Could not give the worktree shell control of the terminal")
        }
        // Foundation gives subprocesses their own process group. A shell may already have
        // stopped on SIGTTIN before foreground ownership was transferred.
        _ = kill(-process.processIdentifier, SIGCONT)
        defer { tm_terminal_reclaim_foreground() }
        return await Task.detached { process.waitUntilExit(); return process.terminationStatus }.value
    }
}
