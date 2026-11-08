import Foundation
import GitHubIntegration
import TaskManagerCore

public struct GitHubDiscoveryResult: Codable, Sendable {
    public let login: String
    public let current: GitHubRepository?
    public let repositories: [GitHubRepository]
}

public struct GitHubDiscovery: Sendable {
    private let client: GitHubClient
    private let git: any GHCommandExecuting

    public init() throws { self.client = try GitHubClient(); self.git = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git")) }

    public init(client: GitHubClient, git: any GHCommandExecuting = GHProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/git"))) {
        self.client = client; self.git = git
    }

    public func discover(checkout: String) async throws -> GitHubDiscoveryResult {
        let login = try await client.authenticatedLogin()
        let current = try await checkoutRepository(checkout)
        let accessible = try await client.accessibleRepositories()
        var seen = Set<String>()
        let repositories = ((current.map { [$0] } ?? []) + accessible).filter { seen.insert($0.slug.lowercased()).inserted }
        return GitHubDiscoveryResult(login: login, current: current, repositories: repositories)
    }

    public func checkoutRepository(_ path: String) async throws -> GitHubRepository? {
        let result = try await git.run(arguments: ["-C", path, "remote", "get-url", "origin"])
        guard result.exitCode == 0 else { return nil }
        return Self.repository(remote: String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func repository(remote: String) -> GitHubRepository? {
        var path: String
        if remote.hasPrefix("git@github.com:") {
            path = String(remote.dropFirst("git@github.com:".count))
        } else {
            guard let url = URLComponents(string: remote), url.host?.lowercased() == "github.com",
                  ["https", "ssh"].contains(url.scheme), url.password == nil,
                  url.query == nil, url.fragment == nil else { return nil }
            path = url.path
            if path.hasPrefix("/") { path.removeFirst() }
        }
        if path.hasSuffix(".git") { path.removeLast(4) }
        return try? GitHubRepository(path)
    }
}
