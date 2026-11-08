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
        public let provenance: String?
        public init(path: String, reference: String, sha: String, provenance: String? = nil) {
            self.path = path; self.reference = reference; self.sha = sha; self.provenance = provenance
        }
    }
    /// Select the PR/branch checkout from source context; otherwise pin the local default branch.
    public func prepareExploration(taskID: String, repository: String, source: IncomingSource? = nil) async throws -> ExplorationSnapshot {
        let namedBranch = try source.flatMap { try explicitBranch($0) }
        let userSelectedBranch = source?.clarification != nil && namedBranch != nil
        if !userSelectedBranch, let source, let context = try await GitHubContextResolver().resolve(source: source, candidates: []) {
            return try await preparePRExploration(taskID: taskID, repository: repository, context: context)
        }
        if let branch = namedBranch {
            let reference = "refs/heads/" + branch
            guard try await GitHubContextResolver.git(repository, ["check-ref-format", reference]) != nil else { throw InspectionContextQuestion("Which valid branch should be inspected?") }
            guard let sha = try await GitHubContextResolver.git(repository, ["rev-parse", "--verify", reference + "^{commit}"]) else {
                throw InspectionContextQuestion("The message names branch \(branch), but that branch is not available locally. Which checkout should be used?")
            }
            let matches = try await GitHubContextResolver.checkouts(repository: repository, branch: branch, sha: sha, headRepository: nil)
            guard matches.count <= 1 else { throw InspectionContextQuestion("Several checkouts use branch \(branch). Which should be inspected?") }
            if let checkout = matches.first {
                return ExplorationSnapshot(path: checkout.path, reference: reference, sha: checkout.sha, provenance: "The source explicitly names branch \(branch). Reusing its existing checkout read-only, including any uncommitted local edits: \(checkout.path).")
            }
            return try await detachedExploration(taskID: taskID, repository: repository, reference: reference, sha: sha, provenance: "The source explicitly names branch \(branch). Inspecting its locally available commit; no fetch was performed.")
        }
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
        return try await detachedExploration(taskID: taskID, repository: repository, reference: reference, sha: sha, provenance: "Local default-branch snapshot; no PR or explicit branch context was identified. No remote refresh was performed.")
    }

    private func detachedExploration(taskID: String, repository: String, reference: String, sha: String, provenance: String) async throws -> ExplorationSnapshot {
        let runner = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git"))
        func git(_ args: [String]) async throws -> String? { try await GitHubContextResolver.git(repository, args) }
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
            return ExplorationSnapshot(path: path, reference: reference, sha: String(decoding: actual.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), provenance: provenance)
        }
        let result = try await runner.run(arguments: ["-C", repository, "worktree", "add", "--detach", path, sha])
        guard result.exitCode == 0 else { throw ManagerError.invalid("Could not create the exploration snapshot") }
        return ExplorationSnapshot(path: path, reference: reference, sha: sha, provenance: provenance)
    }
    private func explicitBranch(_ source: IncomingSource) throws -> String? {
        let text = source.clarification ?? source.body
        let pattern = try NSRegularExpression(pattern: #"(?i)\b(?:branch|ref)\s+[`"']([^`"'\s]+)[`"']"#)
        let references = Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let reference = String(text[range])
            return reference.hasPrefix("refs/heads/") ? String(reference.dropFirst("refs/heads/".count)) : reference
        })
        guard references.count <= 1 else { throw InspectionContextQuestion("The message names several branches. Which branch should this investigation inspect?") }
        return references.first
    }

    private func preparePRExploration(taskID: String, repository: String, context: GitHubRoutingContext) async throws -> ExplorationSnapshot {
        guard GitHubContextResolver.validSHA(context.headSHA) else { throw InspectionContextQuestion("The PR head commit is unavailable. Which checkout should be inspected?") }
        let matches = try await GitHubContextResolver.checkouts(repository: repository, branch: context.headBranch, sha: context.headSHA, headRepository: context.headRepository)
        guard matches.count <= 1 else { throw InspectionContextQuestion("Several checkouts match PR #\(context.pullRequest)'s branch \(context.headBranch). Which should be inspected?") }
        let base = "Source context: \(context.repository) PR #\(context.pullRequest), head branch \(context.headBranch), GitHub head \(context.headSHA)."
        if let checkout = matches.first {
            guard let status = try await GitHubContextResolver.git(checkout.path, ["status", "--porcelain"]),
                  try await GitHubContextResolver.git(checkout.path, ["rev-parse", "HEAD"]) == checkout.sha else {
                throw InspectionContextQuestion("The PR checkout changed while its context was being selected. Please retry when the checkout is ready.")
            }
            let dirty = !status.isEmpty
            let detail = base + "\nReusing existing branch checkout read-only: \(checkout.path) @ \(checkout.sha)." + (dirty ? " Local uncommitted changes are present and included in the inspection." : " Checkout is clean.") + (checkout.sha == context.headSHA ? " HEAD matches the published PR head." : " Local HEAD differs from the published PR head; distinguish local findings from published code.")
            return ExplorationSnapshot(path: checkout.path, reference: "refs/heads/" + context.headBranch, sha: checkout.sha, provenance: detail)
        }
        guard try await GitHubContextResolver.git(repository, ["cat-file", "-e", context.headSHA + "^{commit}"]) != nil else {
            throw InspectionContextQuestion("PR #\(context.pullRequest) refers to branch \(context.headBranch) @ \(context.headSHA), but that commit is not available locally. Please fetch or check out the PR, then answer to retry. I will not inspect main instead.")
        }
        return try await detachedExploration(taskID: taskID, repository: repository, reference: "refs/pull/\(context.pullRequest)/head", sha: context.headSHA, provenance: base + "\nNo matching branch checkout exists; inspecting a detached snapshot of the locally available PR head commit. No fetch was performed.")
    }

    public func validateExploration(session: AgentSessionRecord) async throws {
        guard let workspace = session.workspace, let sha = session.baseSHA else { throw InspectionContextQuestion("This exploration has no recorded inspection commit. Start a fresh source investigation.") }
        let actual = try await GitHubContextResolver.git(workspace, ["rev-parse", "HEAD"])
        let branch = try await GitHubContextResolver.git(workspace, ["symbolic-ref", "-q", "HEAD"])
        let expectedCommon = try await GitHubContextResolver.git(session.repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let actualCommon = try await GitHubContextResolver.git(workspace, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard actual == sha, expectedCommon != nil, actualCommon == expectedCommon, branch == nil || branch == session.baseRef else {
            throw InspectionContextQuestion("The saved inspection checkout changed branch or commit. Start a fresh source investigation for the new context rather than resuming a stale answer.")
        }
    }

}
