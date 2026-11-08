import Foundation
import GitHubIntegration
import TaskManagerCore

public struct InspectionContextQuestion: Error, Sendable {
    public let prompt: String
    public init(_ prompt: String) { self.prompt = prompt }
}

public struct GitHubContextResolver: Sendable {
    private let client: GitHubClient?
    public init(client: GitHubClient? = nil) { self.client = client }

    public static func pullRequest(in source: IncomingSource) throws -> (GitHubRepository, Int)? {
        let fields = source.associationKey.split(separator: ":")
        if fields.count == 4, fields[0] == "github", fields[2] == "pr", let number = Int(fields[3]), number > 0 {
            return (try GitHubRepository(String(fields[1])), number)
        }
        let text: String
        if let clarification = source.clarification, clarification.lowercased().contains("https://github.com/") { text = clarification }
        else { text = source.url + "\n" + source.body }
        let expression = try NSRegularExpression(pattern: #"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)(?:[^0-9]|$)"#, options: .caseInsensitive)
        var found: [String: (GitHubRepository, Int)] = [:]
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let repoRange = Range(match.range(at: 1), in: text), let numberRange = Range(match.range(at: 2), in: text), let number = Int(text[numberRange]), number > 0 else { continue }
            let repository = try GitHubRepository(String(text[repoRange]))
            found[repository.associationKey(pr: number)] = (repository, number)
        }
        guard found.count <= 1 else { throw InspectionContextQuestion("This message references several PRs. Which PR should this work use?") }
        return found.values.first
    }

    public func resolve(source: IncomingSource, candidates: [TriageCandidate]) async throws -> GitHubRoutingContext? {
        if let saved = source.githubContext { return saved }
        guard let (repository, number) = try Self.pullRequest(in: source) else { return nil }
        let client = try client ?? GitHubClient()
        let pull = try await client.pullRequest(in: repository, number: number)
        guard let branch = pull.head.ref, !branch.isEmpty, Self.validSHA(pull.head.sha) else {
            throw InspectionContextQuestion("Could not identify PR #\(number)'s head branch and commit. Which branch should be used?")
        }
        let roots = source.repository.isEmpty ? Array(Set(candidates.map(\.repository))) : [source.repository]
        var matches: [LocalCheckout] = []
        for root in roots {
            matches += try await Self.checkouts(repository: root, branch: branch, sha: pull.head.sha, headRepository: pull.head.repo?.full_name)
        }
        guard matches.count <= 1 else { throw InspectionContextQuestion("PR #\(number)'s branch \(branch) has several matching checkouts. Which checkout should be used?") }
        let checkout = matches.first
        let owner = checkout.flatMap { checkout in
            candidates.first { $0.purpose == .implementation && $0.workspace.map { Self.canonical($0) == Self.canonical(checkout.path) } == true }
        }
        return GitHubRoutingContext(repository: repository.slug, pullRequest: number, headBranch: branch, headSHA: pull.head.sha, headRepository: pull.head.repo?.full_name, checkout: checkout?.path, checkoutSHA: checkout?.sha, owningTaskID: owner?.id)
    }

    struct LocalCheckout: Sendable { let path: String; let sha: String }
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
    static func validSHA(_ sha: String) -> Bool { [40, 64].contains(sha.count) && sha.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
    static func git(_ path: String, _ arguments: [String]) async throws -> String? {
        let result = try await GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git")).run(arguments: ["--no-optional-locks", "-C", path] + arguments)
        return result.exitCode == 0 ? String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    static func checkouts(repository: String, branch: String, sha: String, headRepository: String?) async throws -> [LocalCheckout] {
        guard try await git(repository, ["check-ref-format", "refs/heads/" + branch]) != nil else { throw InspectionContextQuestion("The source branch name is invalid. Which branch should be used?") }
        guard let listing = try await git(repository, ["worktree", "list", "--porcelain", "-z"]) else { throw ManagerError.invalid("Could not inspect repository worktrees") }
        var matches: [LocalCheckout] = []
        var path: String?, head: String?, reference: String?
        for field in listing.components(separatedBy: "\0") {
            if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
            else if field.hasPrefix("HEAD ") { head = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") { reference = String(field.dropFirst(7)) }
            else if field.isEmpty {
                if let path, let head, reference == "refs/heads/" + branch, FileManager.default.fileExists(atPath: path) {
                    var sameRepository = false
                    if let headRepository {
                        var remote = "origin"
                        if let upstream = try await git(path, ["for-each-ref", "--format=%(upstream:remotename)", reference!]), !upstream.isEmpty, upstream != "." { remote = upstream }
                        if let url = try await git(path, ["remote", "get-url", remote]) {
                            sameRepository = GitHubDiscovery.repository(remote: url)?.slug.lowercased() == headRepository.lowercased()
                        }
                    }
                    if head == sha || sameRepository { matches.append(LocalCheckout(path: path, sha: head)) }
                }
                path = nil; head = nil; reference = nil
            }
        }
        return matches
    }
}
