import Darwin
import Foundation
import TaskManagerCore

/// A private, local app-server shared by the coordinator and Codex's terminal client.
actor SharedCodexServer {
    nonisolated let address: String
    private let directory: String
    private var process: Process?
    private var log: FileHandle?
    private var lifeline: Pipe?

    init() {
        directory = "/tmp/task-agent-\(getuid())-\(UUID().uuidString)"
        address = "unix://\(directory)/rpc.sock"
    }

    func start(executable: URL) async throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = directory + "/server.log"
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        log = output
        let child = Process()
        // EOF on this pipe also stops the server after an abrupt coordinator exit.
        // Pass the executable and endpoint as argv; paths never become shell code.
        let pipe = Pipe()
        lifeline = pipe
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", #"""
            "$@" < /dev/null &
            child=$!
            trap 'kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null' EXIT
            trap 'exit 0' INT TERM
            IFS= read -r keepalive
            exit 0
            """#, "task-manager-codex", executable.path, "app-server", "--listen", address]
        child.standardInput = pipe
        child.standardOutput = output
        child.standardError = output
        process = child
        do {
            try child.run()
            try? pipe.fileHandleForReading.close()
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard child.isRunning else { throw ManagerError.invalid("Codex shared server exited. See \(path)") }
                if FileManager.default.fileExists(atPath: directory + "/rpc.sock") { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw ManagerError.invalid("Timed out starting the shared Codex server")
        } catch { await stop(); throw error }
    }

    func stop() async {
        try? lifeline?.fileHandleForWriting.close(); lifeline = nil
        if let child = process, child.isRunning {
            child.terminate()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while child.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        process = nil
        try? log?.close(); log = nil
        try? FileManager.default.removeItem(atPath: directory)
    }
}
