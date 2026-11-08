import Foundation
import GitHubIntegration
import TaskManagerCore
import TaskManagerPersistence
import TaskManagerRuntime
import Testing

private actor DiscoveryCommands: GHCommandExecuting {
    let output: String
    var arguments: [[String]] = []
    init(_ output: String) { self.output = output }
    func run(arguments: [String]) -> GHCommandResult {
        self.arguments.append(arguments)
        return GHCommandResult(exitCode: 0, stdout: Data(output.utf8))
    }
}

private actor DiscoveryHTTP: GitHubHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [HTTPResponse]
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func get(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ManagerError.invalid("Unexpected discovery request") }
        return responses.removeFirst()
    }
}
private func discoveryResponse(_ json: String, next: Bool = false) -> HTTPResponse {
    HTTPResponse(data: Data(json.utf8), status: 200, headers: next ? ["link": "<https://api.github.com/user/repos?page=2>; rel=\"next\""] : [:])
}

@Test func discoveryReusesGHIdentityPaginatesAndPrioritizesCurrentCheckout() async throws {
    let http = DiscoveryHTTP([
        discoveryResponse(#"{"login":"authenticated-person"}"#),
        discoveryResponse(#"[{"full_name":"o/other","archived":false},{"full_name":"o/archived","archived":true}]"#, next: true),
        discoveryResponse(#"[{"full_name":"O/CURRENT","archived":false},{"full_name":"o/disabled","archived":false,"disabled":true}]"#),
    ])
    let git = DiscoveryCommands("git@github.com:o/current.git\n")
    let result = try await GitHubDiscovery(client: GitHubClient(transport: http), git: git).discover(checkout: "/checkout with spaces")
    #expect(result.login == "authenticated-person")
    #expect(result.current?.slug == "o/current")
    #expect(result.repositories.map(\.slug) == ["o/current", "o/other"])
    #expect(await git.arguments == [["-C", "/checkout with spaces", "remote", "get-url", "origin"]])
    let requests = await http.requests
    #expect(requests.map { $0.url!.path } == ["/user", "/user/repos", "/user/repos"])
    #expect(requests[2].url!.query!.contains("page=2"))
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == nil })
}

@Test func githubRemoteInferenceAcceptsSupportedOriginsAndRejectsOtherHosts() {
    for remote in ["git@github.com:owner/repo.git", "https://github.com/owner/repo.git", "ssh://git@github.com/owner/repo.git", "https://github.com/owner/repo"] {
        #expect(GitHubDiscovery.repository(remote: remote)?.slug == "owner/repo")
    }
    for remote in ["https://github.com.evil/owner/repo.git", "git@gitlab.com:owner/repo.git", "/local/repo.git", "https://github.com/owner/repo/extra", "https://github.com/owner/repo?token=secret"] {
        #expect(GitHubDiscovery.repository(remote: remote) == nil)
    }
}

@Test func identityDiscoveryThroughGHDoesNotRequestLoginOrCredentials() async throws {
    let commands = DiscoveryCommands("HTTP/2.0 200 OK\r\n\r\n{\"login\":\"me\"}")
    let client = try GitHubClient(transport: GitHubCLITransport(runner: commands))
    #expect(try await client.authenticatedLogin() == "me")
    let calls = await commands.arguments
    #expect(calls.count == 1)
    #expect(calls[0].prefix(6) == ["api", "--hostname", "github.com", "--method", "GET", "--include"])
    #expect(calls[0].last == "/user")
    #expect(!calls[0].contains("login"))
}

@Test func identityFailureDoesNotInventUserOrQueryRepositories() async throws {
    let http = DiscoveryHTTP([HTTPResponse(data: Data(), status: 401)])
    let git = DiscoveryCommands("git@github.com:o/r.git")
    let service = GitHubDiscovery(client: try GitHubClient(transport: http), git: git)
    await #expect(throws: GitHubError.self) { try await service.discover(checkout: "/checkout") }
    #expect(await http.requests.count == 1)
    #expect(await git.arguments.isEmpty)
}
