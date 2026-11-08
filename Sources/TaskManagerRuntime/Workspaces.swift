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
            let expected = try await runner.run(arguments: ["-C", repository, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            let actual = try await runner.run(arguments: ["-C", workspace, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            let branch = try await runner.run(arguments: ["-C", workspace, "branch", "--show-current"])
            guard expected.exitCode == 0, actual.exitCode == 0, branch.exitCode == 0,
                  expected.stdout == actual.stdout,
                  String(decoding: branch.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "task-manager/\(taskID)" else {
                throw ManagerError.conflict("Existing workspace belongs to a different repository or task branch")
            }
            return workspace
        }
        let result = try await runner.run(arguments: ["-C", repository, "worktree", "add", "-b", "task-manager/\(taskID)", workspace, "HEAD"])
        guard result.exitCode == 0 else { throw ManagerError.invalid("Could not create task worktree. Check the repository has a committed HEAD and branch task-manager/\(taskID) is available.") }
        return workspace
    }
}

extension Workspaces {
    public struct ExplorationSnapshot: Sendable {
        public let path: String
        public let reference: String
        public let sha: String
    }
    /// Inspect a detached default-branch snapshot. Never choose the current feature HEAD.
    public func prepareExploration(taskID: String, repository: String) async throws -> ExplorationSnapshot {
        let runner = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git"))
        func git(_ args: [String]) async throws -> String? {
            let result = try await runner.run(arguments: ["-C", repository] + args)
            return result.exitCode == 0 ? String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        var references: [String] = []
        if let remote = try await git(["symbolic-ref", "refs/remotes/origin/HEAD"]), remote.hasPrefix("refs/remotes/origin/") {
            references += ["refs/heads/" + remote.dropFirst("refs/remotes/origin/".count), remote]
        }
        references += ["refs/heads/main", "refs/heads/master", "refs/remotes/origin/main", "refs/remotes/origin/master"]
        var selected: (String, String)?
        for reference in references {
            if let sha = try await git(["rev-parse", "--verify", reference + "^{commit}"]) { selected = (reference, sha); break }
        }
        guard let (reference, sha) = selected else { throw ManagerError.invalid("No local default-branch reference is available. Fetch or identify the default branch before retrying this exploration.") }
        let directory = URL(fileURLWithPath: stateDirectory).appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(taskID).path
        if FileManager.default.fileExists(atPath: path) {
            let actual = try await runner.run(arguments: ["-C", path, "rev-parse", "HEAD"])
            let common = try await runner.run(arguments: ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            let expected = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"])
            let branch = try await runner.run(arguments: ["-C", path, "symbolic-ref", "-q", "HEAD"])
            guard actual.exitCode == 0, common.exitCode == 0, branch.exitCode != 0,
                  String(decoding: common.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
                throw ManagerError.conflict("Existing exploration workspace belongs to another repository or is not detached")
            }
            // Reconcile a crash after worktree creation: retain the pinned commit, not a moved main.
            return ExplorationSnapshot(path: path, reference: reference, sha: String(decoding: actual.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let result = try await runner.run(arguments: ["-C", repository, "worktree", "add", "--detach", path, sha])
        guard result.exitCode == 0 else { throw ManagerError.invalid("Could not create the default-branch exploration snapshot") }
        return ExplorationSnapshot(path: path, reference: reference, sha: sha)
    }
}
