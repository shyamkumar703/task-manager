import Foundation
import GitHubIntegration
import TaskManagerCore

public struct Workspaces: Sendable {
    let stateDirectory: String
    public init(stateDirectory: String) { self.stateDirectory = stateDirectory }

    public func prepare(taskID: String, repository: String) async throws -> String {
        let directory = URL(fileURLWithPath: stateDirectory).appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = directory.appendingPathComponent(taskID).path
        let runner = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git"), timeout: .seconds(60))
        if FileManager.default.fileExists(atPath: workspace) {
            // Reconcile an already-created workspace after a crash before its DB assignment.
            let result = try await runner.run(arguments: ["-C", workspace, "rev-parse", "--show-toplevel"])
            let root = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0, URL(fileURLWithPath: root).resolvingSymlinksInPath().path == URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path else {
                throw ManagerError.conflict("Existing workspace could not be reconciled: \(workspace)")
            }
            return workspace
        }
        let result = try await runner.run(arguments: ["-C", repository, "worktree", "add", "-b", "task-manager/\(taskID)", workspace, "HEAD"])
        guard result.exitCode == 0 else { throw ManagerError.invalid("Could not create task worktree. Check the repository has a committed HEAD and branch task-manager/\(taskID) is available.") }
        return workspace
    }
}
