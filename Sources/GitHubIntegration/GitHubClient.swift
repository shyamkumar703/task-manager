import CryptoKit
import Foundation
import TaskManagerCore

public struct GitHubRepository: Codable, Sendable, Equatable {
    public let owner: String
    public let name: String

    public init(_ slug: String) throws {
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(allowed.contains) }) else {
            throw ManagerError.invalid("Repository must be OWNER/REPO")
        }
        owner = String(parts[0])
        name = String(parts[1])
    }

    public var slug: String { "\(owner)/\(name)" }
    public func associationKey(pr: Int) -> String { "github:\(slug.lowercased()):pr:\(pr)" }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]

    public init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }
}

public protocol GitHubHTTPTransport: Sendable {
    func get(_ request: URLRequest) async throws -> HTTPResponse
}

public enum GitHubError: Error, Sendable, CustomStringConvertible {
    case http(status: Int, retryAfter: String?)
    case pageLimit
    case cli(exitCode: Int32)

    public var description: String {
        switch self {
        case .http(let status, let retry): "GitHub returned HTTP \(status)" + (retry.map { "; retry after/reset: \($0)" } ?? "")
        case .cli(let code): "gh exited with status \(code). Check gh auth status and network connectivity."
        case .pageLimit: "GitHub pagination limit reached; no partial batch should be committed"
        }
    }
}

public struct GitHubPullRequest: Codable, Sendable {
    public struct User: Codable, Sendable { public let login: String }
    public struct Head: Codable, Sendable { public let sha: String }
    public let number: Int
    public let title: String
    public let user: User
    public let head: Head
}

/// Read-only adapter using gh authentication. Credentials never enter event payloads or logs.
public struct GitHubClient: Sendable {
    private let transport: any GitHubHTTPTransport
    private let maxPages: Int

    public init(transport: any GitHubHTTPTransport = GitHubCLITransport(), maxPages: Int = 100) throws {
        guard maxPages > 0 else { throw ManagerError.invalid("maxPages must be positive") }
        self.transport = transport
        self.maxPages = maxPages
    }

    public func authenticatedLogin() async throws -> String {
        struct User: Decodable { let login: String }
        let result = try await response(path: "/user")
        let login = try JSONDecoder().decode(User.self, from: result.data).login
        try requireText(login, name: "Authenticated GitHub login")
        return login
    }

    public func accessibleRepositories() async throws -> [GitHubRepository] {
        struct Repository: Decodable { let full_name: String; let archived: Bool; let disabled: Bool? }
        let repositories: [Repository] = try await pages(path: "/user/repos", query: [URLQueryItem(name: "sort", value: "pushed"), URLQueryItem(name: "direction", value: "desc")])
        return try repositories.filter { !$0.archived && $0.disabled != true }.map { try GitHubRepository($0.full_name) }
    }

    public func openPullRequests(in repository: GitHubRepository, author: String) async throws -> [GitHubPullRequest] {
        try requireText(author, name: "GitHub author")
        let pulls: [GitHubPullRequest] = try await pages(path: "/repos/\(repository.slug)/pulls", query: [URLQueryItem(name: "state", value: "open")])
        return pulls.filter { $0.user.login.caseInsensitiveCompare(author) == .orderedSame }
    }

    /// Explicit PR selection avoids unintentionally importing repository-wide history.
    /// Returns a complete batch or throws. Caller commits only after every page succeeds.
    public func feedback(in repository: GitHubRepository, pr: Int, excludingAuthor: String? = nil) async throws -> [SourceEvent] {
        guard pr > 0 else { throw ManagerError.invalid("PR number must be positive") }
        let base = "/repos/\(repository.slug)"
        let issue: [Comment] = try await pages(path: "\(base)/issues/\(pr)/comments")
        let inline: [Comment] = try await pages(path: "\(base)/pulls/\(pr)/comments")
        let reviews: [Comment] = try await pages(path: "\(base)/pulls/\(pr)/reviews")
        return [("issue-comment", issue), ("review-comment", inline), ("review", reviews)].flatMap { kind, comments in
            comments.compactMap { comment -> SourceEvent? in
                guard let body = comment.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      comment.state != "PENDING" else { return nil }
                if let excluded = excludingAuthor, comment.user?.login.caseInsensitiveCompare(excluded) == .orderedSame { return nil }
                // Body hashing catches review edits even when submitted_at does not change.
                let revisionInput = [comment.updatedAt ?? comment.submittedAt ?? "", body, comment.state ?? ""].joined(separator: "\n")
                let revision = SHA256.hash(data: Data(revisionInput.utf8)).map { String(format: "%02x", $0) }.joined()
                let context = [comment.user.map { "Author: \($0.login)" }, comment.path.map { "File: \($0)" }, comment.line.map { "Line: \($0)" }, comment.state.map { "Review state: \($0)" }].compactMap { $0 }.joined(separator: "\n")
                return SourceEvent(integration: "github", sourceID: "\(repository.slug.lowercased()):\(kind):\(comment.id)", revision: revision,
                                   associationKey: repository.associationKey(pr: pr), body: context.isEmpty ? body : "\(context)\n\n\(body)", url: comment.htmlURL)
            }
        }
    }

    private func pages<T: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> [T] {
        var values: [T] = []
        for page in 1...maxPages {
            try Task.checkCancellation()
            let response = try await response(path: path, query: query + [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))])
            let batch = try JSONDecoder().decode([T].self, from: response.data)
            values.append(contentsOf: batch)
            // Follow GitHub's next-page signal, rather than trusting a page length heuristic.
            let hasNext = response.headers["link"]?.split(separator: ",").contains(where: { $0.contains("rel=\"next\"") }) ?? false
            if !hasNext { return values }
        }
        throw GitHubError.pageLimit
    }

    private func response(path: String, query: [URLQueryItem] = []) async throws -> HTTPResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ManagerError.invalid("Invalid GitHub API URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("autonomous-task-manager/0.1.0", forHTTPHeaderField: "User-Agent")
        let response = try await transport.get(request)
        guard response.status == 200 else {
            throw GitHubError.http(status: response.status, retryAfter: response.headers["retry-after"] ?? response.headers["x-ratelimit-reset"])
        }
        return response
    }

    private struct Comment: Decodable {
        let id: Int64
        let body: String?
        let htmlURL: String
        let updatedAt: String?
        let submittedAt: String?
        let user: GitHubPullRequest.User?
        let path: String?
        let line: Int?
        let state: String?

        enum CodingKeys: String, CodingKey {
            case id, body, user, path, line, state
            case htmlURL = "html_url", updatedAt = "updated_at", submittedAt = "submitted_at"
        }
    }
}
