import Darwin
import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence

public enum Daemon {
    private static let compatibilityVersion = "task-manager-10"
    public static func requestStop(stateDirectory: String) throws {
        try Data().write(to: URL(fileURLWithPath: stateDirectory).appendingPathComponent("stop-request"), options: .atomic)
    }

    public static func serve(stateDirectory: String) async throws {
        let lock = try CoordinatorLock(stateDirectory: stateDirectory)
        defer { withExtendedLifetime(lock) {} }
        try Data(compatibilityVersion.utf8).write(to: URL(fileURLWithPath: stateDirectory).appendingPathComponent("coordinator.version"), options: .atomic)
        let store = try Store(path: URL(fileURLWithPath: stateDirectory).appendingPathComponent("state.sqlite").path)
        let stopFile = URL(fileURLWithPath: stateDirectory).appendingPathComponent("stop-request")
        try? FileManager.default.removeItem(at: stopFile)
        _ = try await store.recoverAgentSessions()
        try await store.recoverTriage()
        try await store.record(taskID: nil, kind: "coordinator.started", detail: "pid \(ProcessInfo.processInfo.processIdentifier)")
        let coordinator = Coordinator(store: store, stateDirectory: stateDirectory)
        let polling = GitHubPollingScheduler(store: store, client: try GitHubClient())
        let slackPolling = SlackPollingScheduler(store: store, stateDirectory: stateDirectory)
        let oldTerm = signal(SIGTERM, SIG_IGN)
        let oldInt = signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { try? requestStop(stateDirectory: stateDirectory) }
            source.resume()
            return source
        }
        defer {
            sources.forEach { $0.cancel() }
            signal(SIGTERM, oldTerm)
            signal(SIGINT, oldInt)
        }
        do {
            while !Task.isCancelled && !FileManager.default.fileExists(atPath: stopFile.path) {
                try await polling.tick()
                try await slackPolling.tick()
                try await coordinator.tick()
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            await slackPolling.shutdown()
            await polling.shutdown()
            await coordinator.shutdown()
            throw error
        }
        await slackPolling.shutdown()
        await polling.shutdown()
        await coordinator.shutdown()
        try? FileManager.default.removeItem(at: stopFile)
        try await store.record(taskID: nil, kind: "coordinator.stopped", detail: "Active tasks paused; workspaces and threads preserved")
    }

    /// The returned Process should be retained by the UI while attached. It outlives UI detachment.
    public static func start(executable: URL, stateDirectory: String) async throws -> Process? {
        if CoordinatorLock.isRunning(stateDirectory: stateDirectory) {
            let root = URL(fileURLWithPath: stateDirectory)
            let version = try? String(contentsOf: root.appendingPathComponent("coordinator.version"), encoding: .utf8)
            let stopping = FileManager.default.fileExists(atPath: root.appendingPathComponent("stop-request").path)
            if version == compatibilityVersion && !stopping { return nil }
            // Replace older coordinators gracefully before using newer schema and runtime behavior.
            try requestStop(stateDirectory: stateDirectory)
            let deadline = ContinuousClock.now.advanced(by: .seconds(35))
            while CoordinatorLock.isRunning(stateDirectory: stateDirectory) {
                guard ContinuousClock.now < deadline else { throw ManagerError.conflict("Previous coordinator is still stopping. Reopen the TUI after shutdown finishes.") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let log = URL(fileURLWithPath: stateDirectory).appendingPathComponent("coordinator.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let file = try FileHandle(forWritingTo: log)
        defer { try? file.close() }
        try file.seekToEnd()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--state-dir", stateDirectory, "serve"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        try process.run()
        return process
    }
}
